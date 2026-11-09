# seaweedfs

OKDP package of [SeaweedFS](https://github.com/seaweedfs/seaweedfs), a simple
and highly scalable distributed file system with an S3 API: an object store a
platform may deploy as an OKDP instance. It **provides** one `s3` connection,
each consumer bringing its own identity (a grant), and **provisions** `s3`
connections: a bucket and an identity limited to it for each claim bound to its
instance.

Optional: the platform needs an S3 store, an `s3` connection (of `platform.yaml`
for an external store), not this package. The sandbox installs its S3 store with
helm, before anything compiled, and declares it as a connection of the platform.

A package in the okdp-compiler format: the former KuboCD module `main` is the upstream
chart of `Chart.yaml`, rendered from its repository, whose values `values.cel.yaml`
computes from the parameters (`config.schema.json`), over OKDP's defaults
(`seaweedfs.defaults.yaml`, `okdp.yaml`). OKDP's own objects (the `objects` section of
`okdp.yaml`) are rendered by the compiled umbrella chart (`okdp.objects.yaml`):

| Former module | Now | Compiled when |
|---|---|---|
| `main` | chart `seaweedfs` 4.47.0 | always |
| `auth-config` | OKDP's objects: the ESO SecretStore and ExternalSecrets of the S3 and IAM/STS configuration, the STS signing key (ESO Password generator) | always |
| (root identity) | OKDP's objects: ESO Password generators + ExternalSecret `<release>-root-credentials` (`accessKey`, `secretKey`) | `rootCredentialsSecret` empty |
| - | OKDP's objects: the sign-in proxy of the filer UI (oauth2-proxy: Deployment, Service, Ingress, its cookie secret) and its OAuth client (`oidcClients`) | `global.okdp.oidc.enabled` |
| `provisioning` | OKDP's objects: the provisioning ConfigMap and Job (post-install/post-upgrade hook), the buckets and their seeded paths | a bucket, or a claim |

The chart `seaweedfs` 4.47.0 (https://seaweedfs.github.io/seaweedfs/helm, image
`chrislusf/seaweedfs:4.47@sha256:ce9e796f...`) runs master, volume, filer (its UI behind OKDP's sign-in proxy) and the
standalone S3 gateway. Its bucket hook is off (`s3.createBuckets`, which turns it on, is
the package's, `protect`): a pod without `securityContext`, the namespace's default
ServiceAccount's token and the S3 configuration Secret (every identity's keys) mounted,
which no value of the chart changes; the provisioning Job creates the buckets. Its pre-install Secret
`templates/shared/secret-seaweedfs-db.yaml` (a random password, `randAlphaNum`) renders
only with the MySQL filer store (`WEED_MYSQL_ENABLED`, off): instances may not turn it
on (`protect`); the former package removed the template from its vendored copy.
Its ClusterRole `<release>-rw-cr` (pods read and written in every namespace) and
the ClusterRoleBinding to the pods' ServiceAccount are off
(`global.seaweedfs.createClusterRole: false`): a leftover of a migration of the
chart, which no component uses (no seaweedfs binary speaks to the Kubernetes API),
and cluster-scoped objects the confined deployer of a project refuses. So is the
ServiceAccount's token in the pods (`automountServiceAccountToken: false`), which
none reads. The instance's `global` is the compiler's to refuse, and a context's
`global.seaweedfs.createClusterRole` or `automountServiceAccountToken` (a
project's, which Helm gives the chart over the computed one) is refused by
`errors` of `okdp.yaml`.

The buckets, `buckets` and the claims', are created and `buckets[].paths` seeded by the
provisioning Job (OKDP's objects): a post-install/post-upgrade hook Job, idempotent,
running the store's own image. `weed shell` creates each bucket that is not there and
sets its options as the chart's hook did (`objectLock`, `versioning`, `ttl`,
`anonymousRead`), and `weed filer.copy` writes an empty `<path>/.keep` object through
the filer, so no S3 identity is needed. It replaces the chart's bucket hook and the
former `seaweedfs-provisioning` chart and its MinIO client image (`quay.io/minio/mc`,
archived). Its script is fixed: the buckets and paths are data, the files `buckets` (a
line `<name> <anonymousRead> <objectLock> <versioning> <ttl>` each, `-` for none) and
`seed` (a line `<bucket> <path>` each) of its ConfigMap, which it reads into quoted
variables and checks against their patterns again, never shell nor `weed shell` input
built from a value. It runs as user 1000, without privilege escalation, capability or
ServiceAccount token, seccomp `RuntimeDefault`, on a read-only root (`/tmp` an
`emptyDir`).

The names reach that Job's `weed shell` input all the same: the schema allows S3
bucket names only, in `buckets[].name` and `grants[].buckets` (3 to 63 lower-case
letters, digits, dots and hyphens, a letter or a digit first and last, no `..`, no IP
address; a bucket's other keys typed, `ttl` a number and a unit), the s3 contract's
paths in `buckets[].paths` (segments of letters, digits, `.`, `_` and `-` joined by
single slashes, none leading or trailing: a path given as `/logs/` before is refused,
write `logs`), and principal names in `grants[].principal`; a claim's bucket, its ID,
is checked by `errors` too. CI: `ci/bad-*`.

The store's own security, without the chart's `enableSecurity` (its security ConfigMap
writes random JWT keys it reads back with `lookup`, so `helm template` and the install
differ, and its gRPC mTLS leaves a hook without a client certificate):

- the JWT keys of the components, generated once by ESO (Secret
  `<release>-jwt-signing-keys`, keys `volumeWrite` and `filerWrite`, 32 characters
  each), given to every component as `WEED_JWT_SIGNING_KEY`
  and `WEED_JWT_FILER_SIGNING_KEY` (`global.seaweedfs.extraEnvironmentVars`): the volume
  servers take only the writes the master signed, the filer only the writes over HTTP
  that are signed (the S3 gateway signs its own). An instance's environment of a
  component, or a context's `global`, may not replace them (`protect`, `errors`);
- a NetworkPolicy, `<release>-internal`: the master (9333, 19333), the volume servers
  and the filer (8888, 18888) are reached by the release's own pods only (the S3
  gateway, the sign-in proxy, the hooks); their reads and gRPC, which the JWT keys do
  not cover, are no other pod's. The S3 gateway (8333) stays open to its consumers,
  each with its identity. Enforced where the cluster's network plugin enforces
  NetworkPolicies (kind's kindnet does, as Calico and Cilium do).

The former `auth-config` module (`oci://quay.io/okdp/charts/seaweedfs-auth-config`) is
part of this service (OKDP's objects): it read the grants' Secrets with `lookup`, which
differs between Helm and Argo CD. Now:

- the S3 configuration Secret `<release>-s3-config` is written by **ESO**: a SecretStore of
  the kubernetes provider (same namespace, a ServiceAccount allowed to read the root and
  grant Secrets only) and an ExternalSecret templating the identities JSON. It refreshes
  every 5 minutes; Reloader restarts the S3 gateway when it changes. The identities, the
  keys ESO reads for them and the Secrets the Role lets it read are projected from one list
  of principals (the root, the grants, the claims), and the compile fails when the template
  and the references do not pair (CI case `pairing`: eleven grants and two claims);
- the IAM/STS configuration is the Secret `<release>-auth-config` (`iam.json`), also
  written by ESO: SeaweedFS serves no STS without a signing key, so the key is generated
  once by an ESO Password generator (the Secret `<release>-sts-signing-key`, frozen once
  written) and templated into `iam.json`. The S3 gateway waits for that Secret at its
  first start; Reloader restarts it when ESO changes the file, and the pod annotation
  `checksum/iam` (the SHA-256 of the IAM template) rolls it on a change of the template.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `rootCredentialsSecret` | `""` | A Secret of the namespace holding the keys `accessKey` and `secretKey` of the root (Admin) identity of the S3 gateway. Empty: `<release>-root-credentials`, generated once in the cluster by ESO Password generators (an access key of 20 characters, a secret key of 40); read it with `kubectl get secret <release>-root-credentials -o jsonpath='{.data.secretKey}' \| base64 -d`. |
| `stsRoleArn` | `arn:aws:iam::000000000000:role/S3WriteRole` | Role assumed through STS. |
| `consoleHost` / `apiHost` | `seaweedfs.<ns>` / `seaweedfs-api.<ns>` | Host names; the ingress suffix is appended. A non-privileged project's host is `<label>.<ns>` (the compiler refuses others, unless the platform lists them in `global.okdp.policy.ingressHosts`). |
| `oidcAllowedRoles` | `""`: the platform's administrators | Comma-separated claim values allowed to sign in to the filer UI, which reads every bucket; empty: the platform's administrators (`global.okdp.access.admins`). |
| `oidcRolesClaim` | `groups` | Token claim carrying those values. |
| `volumeReplicas` | `1` | Volume servers. |
| `masterStorage`, `masterLogStorage`, `volumeStorage`, `filerStorage`, `filerLogStorage` | `1`, `0.5`, `2`, `0.5`, `0.5` | Sizes in GiB, class `global.okdp.storageClass.workspace`. |
| `grants` | `[]` | `{principal, credentialsSecret: {name, accessKeyKey, secretKeyKey}, actions, buckets, sts}`: one S3 identity each, keys read by ESO from the Secret (in this namespace). |
| `buckets` | `[]` | `{name, anonymousRead, objectLock, versioning, ttl, paths}`: created at install and upgrade by the provisioning Job; `objectLock` (S3 Object Lock, versioning with it, never turned off), `versioning` (`Enabled` or `Suspended`; unset: left as it is) and `ttl` (of the new objects, `<number><m\|h\|d\|w\|M\|y>`) set; `anonymousRead` granted (not revoked when turned off); `paths` are seeded. |
| `outputSecretRef` | `""` | `secretRef` of the published connection; empty: none (consumers bring their own identity). |

Platform values read: `global.okdp.ingress.suffix`, `ingress.className`,
`tls.clusterIssuer`, `storageClass.workspace` (all required); `oidc.enabled`,
`oidc.issuerUri` (required when OIDC is on, an `errors` check), `oidc.scope`,
`oidc.usePKCE`, `oidc.clientProvisioning`, `tls.caBundleSecret` (the CA bundle the
sign-in proxy trusts, none when unset). Needs ESO (a
dependency of the platform, installed before anything compiled; the SecretStore and
ExternalSecret are `external-secrets.io/v1`, served by ESO 0.17 and later) and Reloader
(a dependency of the platform too, the sandbox's bootstrap installs it).

## Images

The two images of the package are named by digest, not by a tag a registry
can move: the store (`chrislusf/seaweedfs:4.47@sha256:ce9e796f...`: the chart,
master, volume, filer, S3 gateway, and the provisioning Job's `weed shell`,
`imageTag` in `okdp.yaml`) and the filer UI's sign-in proxy
(`quay.io/oauth2-proxy/oauth2-proxy:v7.15.4@sha256:b1b2021f...`, the
compiler's `okdpSignInProxy` fragment names it). The digest is the one of the tag's image index, looked up on
2026-11-04 with `crane digest <repository>:<tag>` (a read of the registry;
`skopeo inspect --format '{{.Digest}}' docker://<repository>:<tag>` gives the
same). A new store version is a new package version with its digest looked up
the same way; a mirror (`upstream.seaweedfs.image.registry`) keeps it.

## Upstream values

Any value of the `seaweedfs` chart can be set per instance under `upstream.seaweedfs`,
merged over the values computed from the parameters (`upstream` in `okdp.yaml`):

```yaml
upstream:
  seaweedfs:
    image: {registry: mirror.example.org}
    volume: {resources: {limits: {memory: 1Gi}}}
    s3:
      extraArgs: [-v=2]                            # appended to the chart's arguments
    master: {resources: {limits: {memory: 512Mi}}}
```

The paths the platform relies on are refused, and the lists the chart sets are
appended to rather than replaced: see `protect` and `append` in `okdp.yaml` (also
listed in the schema description). Among them `s3.createBuckets`, the chart's bucket
hook (the buckets are the parameter's), the chart's filer ingress
(`filer.ingresses.http.enabled`, off), and, written in brackets because its key
contains dots, the Reloader annotation of the S3 gateway
(`s3.annotations["secret.reloader.stakater.com/reload*"]`); other annotations stay open.
`s3.extraVolumes` and
`s3.extraVolumeMounts` are strings (they mount the IAM/STS file), so they are refused
rather than appended to. An upstream value wins over the parameter it overlaps
(`volume.replicas` over `volumeReplicas`). No key or value may contain `{{` (the schema
and okdp-compile both refuse it).

## Sign-in of the filer UI

The filer has no login of its own, and its UI reads every bucket (its writes over HTTP
take the filer's JWT, which the UI does not have: upload through the S3 API). With the
platform's OIDC (`global.okdp.oidc.enabled`), an oauth2-proxy (`<release>-filer-proxy`)
signs users in in front of it, at `https://<consoleHost>`: its OAuth client declared in
`oidcClients` (redirect URI `https://<consoleHost>/oauth2/callback`, read from
`platform.oidcClientSecret`), its cookie secret generated once
(`<release>-filer-oauth2-proxy`), the users admitted those whose `oidcRolesClaim` holds
one of `oidcAllowedRoles` (empty, the default: the platform's administrators,
`global.okdp.access.admins`, never every user of the provider). The proxy is the
compiler's `okdpSignInProxy` fragment, on a pod of `okdpPodSpec`, the Job of
the provisioning `okdpJob`. Without OIDC, the UI is not exposed:
`okdp.info.yaml` has no URL, and the S3 API is unchanged. There is no basic auth of the
ingress controller: an `nginx.ingress.kubernetes.io/auth-*` annotation, which another
controller ignores, would leave the UI open.

Since the move onto the compiler's fragments, the proxy no longer passes
`--insecure-oidc-allow-unverified-email`: a user whose email the provider has
not verified is refused (the sandbox realm's users are verified), its cookie
is `_<release>-filer-oauth2-proxy_oauth2` (the sessions of the former name end),
and the finished provisioning Job is deleted after 5 minutes
(`ttlSecondsAfterFinished`, its logs until then).

## Provided connection: `s3`

One output named after the instance, in `okdp.info.yaml`:

```yaml
- name: storage                 # the instance default/storage
  contract: s3
  values: {apiUrl: https://<apiHost>, internalUrl: http://<release>-s3.<ns>.svc.cluster.local:8333,
           consoleUrl: https://<consoleHost>, region: us-east-1, pathStyle: true}
  secretRef: {name: <outputSecretRef>}      # only when outputSecretRef is set
```

An instance of the same namespace references the store by the name of its
output, the release, which resolves to these values (and `secretRef`, when set),
and its release waits for the store's. The store is usually an instance of the
platform's, in its own namespace: consumers of other namespaces claim a bucket (below), or
declare the store as a connection (`connections`) with these values and, as
`secretRef`, a Secret of their namespace holding their own identity's keys (a
grant here).

## Provisioned connections: claims

`provisions: [s3]`: a consumer whose connection reference takes claims
(`x-okdp-connection-ref`'s `provision: true`) claims a bucket instead of naming
a store, and the compiler binds the claim to an instance that provisions the
contract: the one the claim names (`provider`), else the provider of its class
(`class`), else of the default class of the claimer's context. The platform
names this instance in its classes, as a platform that deploys it as the instance
`default/storage` does:

```yaml
# platform.yaml (level 0)
global:
  okdp:
    provisioning:
      s3:
        default: standard
        classes:
          standard: {provider: default/storage}
    secrets:
      store: okdp-secrets   # the claimers are in other namespaces
```

For each claim bound to the instance (`claims`, each `{id, contract, namespace,
name, request}`), with the mechanisms of the values' buckets and grants:

| What | Name | How |
|---|---|---|
| bucket | the claim's ID, a valid bucket name (`demo.lake`) | the provisioning Job (post-install and post-upgrade), as `buckets` |
| seeded paths | `<path>/.keep` in the bucket | the provisioning Job, as `buckets[].paths` |
| S3 identity | the claim's ID | `Read`, `List` and `Write` on its bucket only, in the S3 configuration ESO writes (`<release>-s3-config`) |
| credentials Secret | `<id>-s3-credentials` | `accessKey` and `secretKey`, generated once by ESO (`provides` `secret.generate`), labelled `okdp.io/credentials-s3: "true"`; ESO reads them into the S3 configuration, Reloader restarts the gateway |

The claim's connection, an output named after its ID, is what its claimers
receive; they never name it:

```yaml
- name: demo.lake
  contract: s3
  values: {apiUrl: https://<apiHost>, internalUrl: http://<release>-s3.<ns>.svc.cluster.local:8333,
           bucket: demo.lake, paths: [raw, curated/v1], region: us-east-1, pathStyle: true}
  secretRef: {name: demo.lake-s3-credentials}
```

What a claim requests, the contract's claim schema (`x-okdp-claim` of
`contracts/s3.schema.json`), its defaults applied: `paths`, the prefixes seeded
in its bucket, published as granted. A bucket of the values named after a
claim's ID, or a grant whose principal is one, fails the compile.

The bucket outlives the claim: when no instance claims it any more, the compile
drops its identity, its Secret and its line of the provisioning Job, and the store
keeps the bucket and its objects. A claimer that comes back, under the same ID,
finds its bucket, with new keys. Delete a bucket by hand (`weed shell`,
`s3.bucket.delete`).

A claimer of another namespace gets the keys through the platform's secret store
(`global.okdp.secrets.store`): the compiler writes a `PushSecret` in this
instance's objects and an `ExternalSecret` in the claimer's. Without the store,
such a claim is refused. The store is the platform's: the sandbox creates it
with External Secrets at bootstrap.

## Changes from the KuboCD package

- The output was named `s3` (connection `kcd-<release>-s3`); it is the instance's name.
- The filer UI was behind ingress-nginx's basic auth (`username`, `password`, the Secret
  `creds-seaweedfs-filer-basic`), which another ingress controller ignores, leaving it
  open: it is behind an oauth2-proxy with the platform's OIDC (`<release>-filer-proxy`,
  admitted roles `oidcAllowedRoles`), and not exposed without OIDC. `username` and
  `password` are gone.
- Secrets and ConfigMaps are named after the release (the TLS Secrets `<release>-filer-tls` / `<release>-s3-tls`,
  the ServiceAccount `<release>`).
- The S3 configuration follows grant Secret changes (ESO refresh + Reloader); it was
  rewritten only on a Helm upgrade.
- Hosts are parameters (default `seaweedfs.<ns>` and `seaweedfs-api.<ns>`, were `<release>-<ns>[-api]`; the API host used to be `seaweedfs-<ns>-api`; D4: `<label>.<ns>`, the old `<x>-<ns>` hosts are gone).
- The volume PVC resize hook is off (it compared live PVCs with `lookup`).
- `outputSecretRef` is new.
- The root identity's keys are no values any more (`rootAccessKey` and
  `rootSecretKey`, which put a credential in Git, are gone): they are generated
  once in the cluster by ESO into `<release>-root-credentials`, or read from the
  Secret `rootCredentialsSecret` names. An existing release gets new root keys,
  which the S3 configuration follows (ESO refresh, Reloader): read them from the
  Secret.
- Seeded paths are written with the SeaweedFS image (`weed`) instead of the MinIO client.
- The chart's bucket hook is off: the provisioning Job creates the buckets.
  `upstream.seaweedfs.s3.createBuckets` is refused; its `objectLock`, `versioning`
  and `ttl` are keys of `buckets` (`versioning` `Enabled` or `Suspended`).
- No ClusterRole `<release>-rw-cr` nor ClusterRoleBinding, no ServiceAccount token
  in the pods (they were the chart's defaults).

## Known gaps

What the okdp-lib-chart wrapper did to the rendered objects and a mapping cannot
express (okdp-compiler gap list):

- the values ConfigMap `<release>-seaweedfs-values` (`okdp.io/vendor-values`) is gone:
  the compiled values replace it. What the instance publishes (its URL, usage and the
  s3 output) is `okdp.info.yaml`, next to the compiled umbrella chart, no longer the
  descriptor ConfigMap `<release>-okdp`.

## Tests

`ci/platform.yaml` holds the platform values of every case, OIDC on (the sign-in
proxy of the filer UI); `no-oidc` turns it off: no proxy, no URL; `grants-sts-buckets`
has its own suffix, issuer and storage class
(`ci/grants-sts-buckets-platform.yaml`), and its root identity's keys in a
Secret of the namespace (`rootCredentialsSecret`), the other cases generating
them; `mysql-filer` must fail. `claims` is
the provider of the claims of the project `demo` (`ci/claims-project.yaml`),
beside a grant, a bucket and its own output: the instance under test is the
provider of the default class (`ci/claims-platform.yaml`), and of the project's
class `events`, which fixes the paths of its claims; `lake` is of the default
class, `spark-events` of the class `events`, `scratch` names its provider.
`bad-request` must fail: a claim requests what the contract does not allow.
`bad-upstream-bucket` must fail: a bucket appended to the chart's `s3.createBuckets`.
`bucket-clash` must fail: a bucket of the values is named after a claim's ID.
`admins` has an empty `oidcAllowedRoles` and the platform's administrators `ops`
(`ci/admins-platform.yaml`): they sign in. `no-admins` must fail: empty, and
no administrator.
The case `claims` also holds the two claimer projects `a-b` and `a`
(`ci/claims-projects/`), whose instances `d` and `b-d` claim the buckets
`a-b.d.bucket` and `a.b-d.bucket`, IDs a lossy mapping (dots and dashes both
`_`) would make one name; the instance under test provisions both (a bucket
and an identity each, named after the ID, which keeps them apart).

Its cases, `ci/*-values.yaml`, compile by hand as the repository's
[README](../../../README.md#working-on-a-package) shows.
