# s3-minio-provisioner

OKDP package that **provisions** `s3` connections on an S3 store OKDP neither
deploys nor manages. It uses MinIO's admin API, which MinIO and RustFS both serve
under `/minio/admin/v3/`. For each claim bound to its instance, it creates a
bucket and an identity limited to that bucket, whose keys are generated in the
cluster, and seeds the prefixes the claim requests.

It deploys no store. The store is a platform dependency, such as the sandbox's
RustFS (installed with helm by `bootstrap/`) or a company's MinIO, and the
instance reaches it through an `s3` connection. This package is to such a store
what `seaweedfs` is to its own: the provider that the platform's classes of `s3`
connections name.

A package in the okdp-compiler format, with no upstream chart (no dependency in
`Chart.yaml`). `okdp.yaml` computes OKDP's own objects from the parameters
(`config.schema.json`) and the claims, and publishes one connection per claim
(`provides`, in `okdp.info.yaml`):

| Objects | Compiled when |
|---|---|
| per claim, its credentials Secret `<id>-s3-credentials` (`accessKey` of 20 characters, `secretKey` of 40), generated once by ESO Password generators | a claim is bound to the instance |
| the provisioning ConfigMap and Job `<release>-provision` (a post-install/post-upgrade hook) | a claim is bound to the instance |

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `store` | `""` | **Required.** The store the claims are provisioned on: the name of an `s3` connection (usually the project's), or of an output of another instance of the namespace. The connection must have a `secretRef` (`require`). Its credentials Secret, with keys `accessKey` and `secretKey`, is the identity the Job provisions with. |
| `adopt` | `false` | Adopt an existing bucket of a claim's name that carries no `okdp.io/claim` tag (it is tagged then). Otherwise such a claim is refused, see [claims](#provisioned-connections-claims). Set it for one run, for the buckets an earlier version of this package created. |
| `image` | `docker.io/library/node:24.22.2-alpine3.24@sha256:8a32c8cf...` | The Job's image: Node.js 22 or later, standard library only. By digest, `repository[:tag]@sha256:...` (the schema refuses a name without one: the Job holds the store's provisioning identity). Use a mirror from the platform's registries, with its digest. |

The digest is the one of the tag's image index, looked up on 2026-11-04 with
`crane digest docker.io/library/node:24.22.2-alpine3.24` (or `skopeo inspect
--format '{{.Digest}}' docker://...`, a read of the registry); a new Node.js
version is looked up the same way.

The store's connection gives:

- the Job's endpoint: `internalUrl`, else `apiUrl`. It must be an `http://` or
  `https://` URL; any path is kept as a prefix of every request;
- the region requests are signed for: `region`, `us-east-1` by default;
- what the claims' connections publish: `apiUrl`, `internalUrl`, `region`,
  `pathStyle`;
- the provisioning identity: its `secretRef`.

When the platform sets a CA bundle (`global.okdp.tls.caBundleSecret`, key
`ca.crt`) and the endpoint is `https://`, the Job trusts that bundle
(`NODE_EXTRA_CA_CERTS`).

### The provisioning identity

The identity needs these permissions from the store, and nothing on the objects
of any bucket:

```json
{"Version": "2012-10-17", "Statement": [
  {"Effect": "Allow", "Action": ["admin:CreateUser", "admin:CreatePolicy", "admin:AttachUserOrGroupPolicy"]},
  {"Effect": "Allow", "Action": ["s3:CreateBucket", "s3:GetBucketTagging", "s3:PutBucketTagging"],
   "Resource": ["arn:aws:s3:::*"]}]}
```

An admin statement takes no `Resource`: MinIO ignores it, and RustFS refuses
`"*"`. Since the identity can attach any policy to any user, including itself,
it is effectively as trusted as the store's root. Keep its key where only the
provisioner's namespace reads it: in the platform's secret store, under that
namespace's keys (`secretRef: {remoteKey: <namespace>/<key>}`). Never put it
under `platform/`, which every namespace reads.

The sandbox's bootstrap creates this identity in RustFS (`okdp-provisioner`,
Secret `rustfs/rustfs-provisioner`, `bootstrap/rustfs/values.yaml`). OpenBao's
init writes it under `<S3_PROVISIONER_NAMESPACE>/s3-provisioner`, `s3-system`
by default (`bootstrap/openbao/init.sh`). The project of that namespace then
declares the store:

```yaml
# projects/s3-system/project.yaml
connections:
  rustfs:
    contract: s3
    apiUrl: https://s3.okdp.sandbox
    internalUrl: http://rustfs-svc.rustfs.svc.cluster.local:9000
    pathStyle: true
    secretRef: {remoteKey: s3-system/s3-provisioner}
```

```yaml
# projects/s3-system/instances/s3-minio-provisioner/config.yaml
store: rustfs
```

## Provisioned connections: claims

`provisions: [s3]`: a consumer whose connection reference takes claims
(`x-okdp-connection-ref`'s `provision: true`, as spark-history-server's
`storage` in `OKDP/platform-charts`) claims a bucket instead of naming one. The
compiler binds the claim to the provider of its class, or to the provider the
claim names. The platform names this instance in its classes:

```yaml
# platform.yaml (level 0)
global:
  okdp:
    provisioning:
      s3:
        default: standard
        classes:
          standard: {provider: s3-system/s3-minio-provisioner}
    secrets:
      store: okdp-secrets   # the claimers are in other namespaces: see below
```

For each claim bound to the instance (`claims`, each `{id, contract, namespace,
name, request}`), the Job does the following on the store, as the provisioning
identity. Every step is idempotent, and the Job runs again at every install and
upgrade:

| On the store | Name | |
|---|---|---|
| bucket | the claim's ID (`demo.spark-history.storage`, `demo.lake`) | created if missing, then tagged `okdp.io/claim=<id>`; one that exists (MinIO answers `BucketAlreadyOwnedByYou`, RustFS `BucketAlreadyExists`) is kept only if it carries that tag, see below |
| policy | `okdp-claim-<id>` | `s3:GetBucketLocation`, `s3:ListBucket` and `s3:ListBucketMultipartUploads` on the bucket; `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload` and `s3:ListMultipartUploadParts` on its objects; rewritten at each run |
| user | the access key of the claim's Secret | its secret key the Secret's, the policy attached (`set-user-or-group-policy`) |
| `<path>/.keep` | each path the claim requests | an empty object, written with the claim's own identity |

A bucket that exists on the store when the Job first meets the claim is not
necessarily the claim's: the store's buckets are one namespace, an operator's
bucket or another system's can bear the name a claim's ID gives (`demo.lake`).
The Job therefore tags the buckets it creates (`okdp.io/claim=<claim ID>`) and
takes an existing one only when it carries the tag of this claim. Otherwise
the claim is **refused**: no policy, no user, no seeded path, the message
`claim <id>: the bucket <id> exists and was not created by this provisioner`
(or `belongs to the claim <other id>`) in the Job's log; the other claims are
served and the Job ends failed so that it is seen. `adopt: true` (a parameter
of the provider's instance, so the platform's operators', never a claim's)
takes the existing buckets that carry no tag at all, and tags them: set it
once for the buckets an earlier version of this package created (they have no
tag) or one an operator made for the claim, then set it back to `false`. A
bucket tagged for another claim is never adopted. A Job that dies between the
creation of a bucket and its tag leaves it untagged: adopt it the same way.

A claim's ID is DNS-1123 labels joined by dots, 63 characters at most, which
is always a valid bucket name. The claim's connection is an output named after
its ID, and is what its claimers receive:

```yaml
- name: demo.spark-events
  contract: s3
  values: {apiUrl: https://s3.okdp.sandbox, internalUrl: http://rustfs-svc.rustfs.svc.cluster.local:9000,
           bucket: demo.spark-events, paths: [event-logs], region: us-east-1, pathStyle: true}
  secretRef: {name: demo.spark-events-s3-credentials}
```

A claim requests what the contract's claim schema allows (`x-okdp-claim` of
`contracts/s3.schema.json`): `paths`, the prefixes to seed.

The data outlives the claim. When no instance claims it any more, the compile
drops the claim's Secret and its entry in the Job. The bucket, the user and the
policy stay on the store: the store is not OKDP's, and nothing removes them. A
claimer that comes back under the same ID finds its bucket, with a new
identity. Remove the old user, the policy and the bucket by hand.

A claimer in another namespace gets the credentials through the platform's
secret store (`global.okdp.secrets.store`). The compiler writes a `PushSecret`
among this instance's objects and an `ExternalSecret` among the claimer's.

### The admin API without a client

The Job is a small client of MinIO's admin API written in JavaScript, using
only Node's standard library (`fetch`, `crypto`), in the ConfigMap
`<release>-provision` (`provision.mjs`, with `claims.json`, which holds no
key). It needs no `mc`, whose images MinIO no longer publishes:

- requests are signed with AWS Signature V4 (service `s3`, the store's region);
- the body that `add-user` must receive encrypted is sealed as madmin's
  `EncryptData` does: a 32-byte salt, the algorithm `0x02` (PBKDF2-SHA256 with
  8192 rounds and AES-256-GCM, accepted by FIPS builds too), an 8-byte nonce,
  then the sio DARE stream, keyed with the provisioning identity's secret key;
- `add-canned-policy` and `set-user-or-group-policy` take plain bodies and
  queries;
- it retries for 5 minutes while the store is unreachable or answers 5xx, and
  while a user it just created is not yet known. Any other answer fails the
  Job, which Kubernetes then retries (`backoffLimit: 20`). It never prints a
  key.

The Job is the compiler's `okdpJob` fragment: the pod runs as user 1000, without a
ServiceAccount token, with a read-only root file system, no capabilities and the
`RuntimeDefault` seccomp profile; the finished Job is deleted after 5 minutes
(`ttlSecondsAfterFinished`).
The claims' Secrets are mounted read-only, so the pod starts once External
Secrets has generated them.

Verified against `rustfs/rustfs:1.0.0` (the chart `rustfs` 1.0.0 of the
bootstrap) and MinIO `RELEASE.2026-10-23T20-06-51Z`, both with the provisioning
identity's policy above:

- the provisioning identity creates buckets, users and policies, and is refused
  server info, user removal, reading objects and deleting buckets;
- each claim's identity lists, reads and writes its own bucket, and is refused
  the other buckets, bucket deletion and the admin API;
- a second run changes nothing.

The bucket tag (`PutBucketTagging`, `GetBucketTagging`) and the refusal of an
untagged bucket were run against a fake S3 server that implements the calls
(buckets, tags, the admin routes), not against RustFS or MinIO: check that
both store the tag and answer `NoSuchTagSet` on an untagged bucket (kind run).

## Known gaps

- The bucket, the user and the policy of a claim that is gone are never removed.
  No quota is granted: the contract's claim schema requests none.
- A user is created per access key. A claim Secret regenerated with a new key
  leaves the old user on the store.
- One store per instance. Several stores need several instances, each with its
  class.

## Tests

`ci/platform.yaml` makes the instance under test the provider of the default
class of `s3` connections. The cases:

- `claims`: the store is a connection of the project, with an http
  `internalUrl`. The project declares three named claims, one of the default
  class with two paths, one of its class `events`, which fixes a path, and one
  naming its provider.
- `sandbox`: the sandbox's layout. RustFS's provisioning identity is read from
  OpenBao (`remoteKey: demo/s3-provisioner`, demo being the cases' namespace),
  with one claim of Spark's event logs.
- `https`: the store's https `apiUrl` only, with virtual-host addressing; the
  platform's CA bundle is mounted.
- `idle`: no claim, so no Job and no connection.

The case `claims` also holds the two claimer projects `a-b` and `a`
(`ci/claims-projects/`), whose instances `d` and `b-d` claim the buckets
`a-b.d.bucket` and `a.b-d.bucket`: IDs a lossy mapping (dots and dashes both
`_`) would make one name. The instance under test provisions both, two
buckets, two policies, two Secrets (the buckets are the IDs themselves), and
the compiler refuses two objects of one name.

- `no-store` must fail: a claim is bound to the instance, which names no store.
- `bad-endpoint` must fail: the store's endpoint is not a URL.
- `adopt`: the same with `adopt: true`, the Job's configuration carries it.
- `bad-image` must fail: the Job's image names a tag, no digest.

Its cases, `ci/*-values.yaml`, compile by hand as the repository's
[README](../../../README.md#working-on-a-package) shows.
