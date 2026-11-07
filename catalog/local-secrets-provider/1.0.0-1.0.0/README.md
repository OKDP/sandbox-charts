# local-secrets-provider

OKDP package writing the Kubernetes Secrets the platform services need from a list: a
local stand-in for an external secret manager in sandbox environments. Each Secret's
credentials are never values of the instance: nothing secret is in Git, in the compiled
tree or in a rendered manifest. External Secrets Operator (ESO) either generates them,
random values, once in the cluster (`generate`), or reads them from the platform's
secret store (`remoteKey`), where whoever installed the other side put them (the
identity provider's bootstrap writing an OAuth client's secret, for instance). Its other
keys are static values that are no credential (a `client_id`, a username, a port).
Each Secret stays in the instance's namespace, which is all a tenant's instance may
reach: it reads its namespace's keys of the store only, it is copied nowhere (no
replication), and it carries no label of OKDP's or of a replicator.

A package in the okdp-compiler format, with no upstream chart (no dependency in
`Chart.yaml`): `okdp.yaml` writes, for each entry of the parameters below
(`config.schema.json`), OKDP's own objects (its `objects` section, rendered by the
compiled umbrella chart, `okdp.objects.yaml`): for a generated Secret, the objects of
`okdpGeneratedSecret`, an ESO `Password` generator per generated key and the
`ExternalSecret` writing the Secret; for a Secret read from the store, the
`ExternalSecret` alone. The former module `main`, the chart
`oci://quay.io/okdp/charts/local-secrets-provider`, is no longer used: the version the
previous package rendered, 0.2.0 (the per-entry `labels`), was never published, and its
one template wrote a Secret of the values' literals per entry.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `secrets` | `[]` | List of `{name, generate: [{key, length, digits, symbols, noUpper, transform}], data: {<key>: <value>}, labels: {<key>: <value>}}` or `{name, remoteKey: <key>, properties: [<property>...], data, labels}`, one Secret each; names unique. An entry has `generate` (one key at least) or `remoteKey` and `properties`, one or the other; `data` and `labels` are optional. |

- `generate`: the keys whose values ESO generates, one `Password` generator each
  (`<name>-<key>`): `length` (default `32`), `digits` (default `6`), `symbols` (default
  `0`), `noUpper` (default `false`), `transform` (`sha256`: the key holds the SHA-256
  of the value, 64 hexadecimal characters, e.g. a 32-byte key such as
  `JUPYTERHUB_CRYPT_KEY`; `b64enc`: its base64).
- `remoteKey`: the key of the platform's secret store (`global.okdp.secrets.store`) the
  Secret's credentials are read from, and `properties`, the properties of that key
  read, each a key of the Secret of the same name. A key is a path, its segments
  separated by `/`, none empty, `.` or `..`, under the instance's namespace,
  `<namespace>/`, only: another namespace's key is refused, whatever the store's policy
  allows, and so is a platform key, under `platform/`, which every namespace may read
  in the store: a platform key is read by a platform connection
  (`secretRef.remoteKey`, the compiler's ExternalSecret), not by this package. What one
  namespace needs from the store is written under its keys (the sandbox's bootstrap
  writes a Keycloak client's secret under `<namespace>/keycloak/<client>` of the
  namespaces that read it).
- `data`: static keys, written as text beside the generated or read ones; no credential.
  A key cannot be both generated, or read, and static, and a value cannot be empty.
- `labels` are added to the Secret, next to OKDP's labels (which win). A key under
  `okdp.io/` (or a subdomain of it: OKDP's, `okdp.io/protected` the deletion protection,
  `okdp.io/instance` an instance's objects) or `replicator.v1.mittwald.de/` (a
  replicator's, which would copy the Secret to other namespaces) is refused. Database
  owner Secrets read by CloudNativePG managed roles (cnpg-postgresql
  `owner.passwordSecret`) need `cnpg.io/reload: "true"`: otherwise a role reconciled
  before its Secret exists keeps no password (see the cnpg-postgresql README).
- `replicateTo` is gone: an entry that sets it is refused (the schema), and no Secret
  carries a replicator's annotation.

```yaml
secrets:
  - name: creds-seaweedfs-s3                 # an S3 identity, generated
    generate: [{key: accessKey, length: 20}, {key: secretKey, length: 40}]
  - name: okdp-control-plane-keycloak        # a client the identity provider's bootstrap created,
    remoteKey: okdp-system/keycloak/okdp-control-plane  # an instance of okdp-system
    properties: [client_secret]
    data: {client_id: okdp-control-plane}
```

An entry with neither `generate` nor `remoteKey`, or with both, is refused: its
credentials would be values of the instance, or two sources for one Secret.

### Generated

The values are generated once (the ExternalSecret's `refreshInterval: "0"`) and kept
while the ExternalSecret lives: every render of the release is the same, and nothing
rotates them. A generated Secret is frozen once written: changing its keys regenerates
its values, so give it a new name instead. Read a value with
`kubectl get secret <name> -o jsonpath='{.data.<key>}' | base64 -d`.

A party that must hold the same value, outside the cluster's Secrets (the identity
provider registering an OAuth client with that secret, an S3 store creating that
identity), reads it from the Secret, in the instance's namespace: the value no longer
comes from a file of both sides. When that party is installed first and makes the value
itself, read it from the store instead (below). For OAuth clients, dynamic client
registration (`clientProvisioning: dcr`) needs no shared secret at all.

### Read from the platform's secret store

The `ExternalSecret` reads each property of `remoteKey` from the platform's secret
store, as the compiler's own do (a connection's `secretRef.remoteKey`): the SecretStore
`global.okdp.secrets.store` of the namespace when the platform gives its provider
(`global.okdp.secrets.provider`, the SecretStore the compiler writes in each project's
namespace), else the ClusterSecretStore of that name; every
`global.okdp.secrets.refreshInterval` (`1h`), so a value changed in the store reaches
the Secret within it. The Secret is the ExternalSecret's (`creationPolicy: Owner`): its
read keys and its static data. A platform without a store
(`global.okdp.secrets.store`) refuses the entry. The store's policy must let the
namespace read the key (the sandbox's OpenBao gives every namespace its own
`<namespace>/*`).

## What the instance publishes

No connection (a Secret of this package matches no contract): the instance's usage, in
`okdp.info.yaml`, lists the Secrets it writes, their generated or read keys and their
static keys. A service reads one by its name, as its parameters name a Secret (a
`credentialsSecret`, an `s3SecretRef`, the OAuth client Secret `creds-<release>-oauth2`
of `clientProvisioning: existing`), in the instance's namespace: a service of another
namespace has an instance of this package in its own.

## Upstream values

None: the service renders no upstream chart. The former `upstream.local-secrets-provider`
(the chart's `nameOverride`, the `app.kubernetes.io/name` label of the Secrets) is gone;
an instance that sets `upstream` is refused by the schema.

## Changes from the KuboCD package

- The credentials are never values of the instance, which put them in Git: they are
  generated in the cluster by ESO (`generate`), or read by it from the platform's secret
  store (`remoteKey`). `data` holds the static keys only, no credential, and an entry
  with neither is refused. Needs External Secrets Operator, a dependency of the
  platform, and, to read, the platform's secret store. The Secret is written by its
  `ExternalSecret` (`creationPolicy: Owner`), with the labels in the ExternalSecret's
  template.
- No replication: the former chart annotated every Secret for kubernetes-replicator,
  which copied it to every namespace; `replicateTo` is gone. An instance reads its
  namespace's keys of the store only, never `platform/`, and sets no label under
  `okdp.io/` or `replicator.v1.mittwald.de/`.
- Empty values are refused (schema and mapping). The former chart marked them
  `secret-generator.v1.mittwald.de/autogenerate` for kubernetes-secret-generator, which
  the platform's tools no longer ship; a value generated in the cluster after Helm applied
  the Secret was drift for Flux and Argo CD anyway. A random value is a key of
  `generate`.
- Two entries of one name are refused (the former chart merged them into one Secret).
- The Secrets carry OKDP's labels (`app.kubernetes.io/part-of: okdp`, `okdp.io/instance`,
  `okdp.io/service`), no longer the chart's `helm.sh/chart` and
  `app.kubernetes.io/version`.

## Known gaps

What the okdp-lib-chart wrapper did to the rendered objects and a mapping cannot
express (okdp-compiler gap list):

- the values ConfigMap `<release>-local-secrets-provider-values`
  (`okdp.io/vendor-values`) is gone. What the instance publishes (its usage) is
  `okdp.info.yaml`, next to the compiled umbrella chart, no longer the descriptor
  ConfigMap `<release>-okdp`.

## Tests

The platform values the cases read are the secret store's, `global.okdp.secrets`:
`ci/platform.yaml` gives every case a ClusterSecretStore, `okdp-secrets`. `sandbox`
generates an OAuth client's secret, a JupyterHub crypt key (`transform: sha256`), an S3
identity and a database owner's password with static keys and a label, and reads a
Keycloak client's secret from `demo/keycloak/<client>`, a key of its namespace,
through the SecretStore of the namespace, as the sandbox's (`sandbox-platform.yaml`,
OpenBao). `cluster-store` reads two keys of the namespace from the ClusterSecretStore,
every 15 minutes. `duplicate`, `empty-value`, `both` (a key generated and static),
`no-generate` (static values only), `generate-and-remote`, `no-properties`, `no-store`
(a platform without store), `other-namespace`, `platform-key` (a key under
`platform/`), `bad-key` (a `..` segment), `read-and-static` (a key read and static),
`okdp-label` (`okdp.io/protected`), `replicator-label`
(`replicator.v1.mittwald.de/replicate-to`) and `replicate-to` (the removed
`replicateTo`) must fail.

Its cases, `ci/*-values.yaml`, compile by hand as the repository's
[README](../../../README.md#working-on-a-package) shows.
