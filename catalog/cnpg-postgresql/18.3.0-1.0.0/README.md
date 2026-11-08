# cnpg-postgresql

OKDP package of one PostgreSQL cluster managed by the
[CloudNativePG](https://cloudnative-pg.io/) operator (a dependency of the
platform, installed before anything compiled), hosting several logical
databases, each with its owner role. It **provides** one `database-server`
connection per database of its values, and **provisions** `database-server`
connections: a database, its owner role and the role's credentials for each
claim bound to its instance.

A package in the okdp-compiler format, with no upstream chart (no dependency in
`Chart.yaml`): `okdp.yaml` computes the `Cluster` and the `Database` objects from the
parameters below (`config.schema.json`) as OKDP's own objects (its `objects` section,
rendered by the compiled umbrella chart, `okdp.objects.yaml`), and the connections the
instance publishes (`provides`, in `okdp.info.yaml`):

| Former module | Now | Compiled when |
|---|---|---|
| `main` | OKDP's objects: the `Cluster` and one `Database` per database | always |
| none | OKDP's objects: per claim, a managed role, a `Database` and the role's generated credentials Secret | a claim is bound to the instance |

The templates of the former module (`oci://quay.io/okdp/charts/cnpg-postgresql` 0.1.0)
are part of the mapping (`okdp.yaml`): that chart checked the owner Secrets with `lookup`, which renders
nothing under Argo CD, and no value disables it. A missing Secret now shows in the
`Cluster` status.

## Image

The cluster runs `ghcr.io/cloudnative-pg/postgresql:18.3` by digest
(`@sha256:5e30290f...`, `imageName` of the `Cluster` in `okdp.yaml`), not by a
tag the registry can move. The digest is the one of the tag's image index,
looked up on 2026-11-04 with `crane digest ghcr.io/cloudnative-pg/postgresql:18.3`
(or `skopeo inspect --format '{{.Digest}}' docker://...`, a read of the
registry). A new PostgreSQL version is a new package version, its digest
looked up the same way.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `databases` | (required) | `[{name, owner: {username, passwordSecret}, schemas: []}]`, beside the databases of the claims. |
| `instances` | `1` | PostgreSQL instances (1 primary + standbys). |
| `storageSize` | `2Gi` | Volume of each instance; class `global.okdp.storageClass.data` (cluster default when unset). |
| `databaseReclaimPolicy` | `delete` | `delete` or `retain` a database removed from the list. |

`owner.passwordSecret` is a Secret of the release namespace with the keys `username` and
`password`, created by someone else (`local-secrets-provider` in the sandbox, an instance
in the release namespace).

**Label the owner Secrets `cnpg.io/reload: "true"`.** CloudNativePG reconciles a
managed role when the `Cluster` changes, and when a Secret it uses changes only
if that Secret carries this label. A Secret that appears after the role was
reconciled (a Secret External Secrets writes arrives some time after the chart)
otherwise leaves the role without a password for good (`passwordStatus`
of the role without `resourceVersion`), and every client fails with `password
authentication failed`. With the label, CloudNativePG sets the password as soon
as the Secret appears, and again when it changes. `local-secrets-provider` sets
it per Secret (`labels`). The credentials Secrets of the claims carry it (below).

## Provided connections: `database-server`

For each database, an output named `<release>-<database>` (`_` becomes `-`), in
`okdp.info.yaml`:

```yaml
- name: cnpg-system-cnpg-postgresql-keycloak
  contract: database-server
  values: {engine: postgresql, driver: org.postgresql.Driver, sslMode: prefer, port: 5432,
           host: cnpg-system-cnpg-postgresql-rw.cnpg-system.svc.cluster.local, dbName: keycloak}
  secretRef: {name: creds-keycloak-db}
```

A cluster publishes several outputs, one per database. An instance of the same
namespace references one by its name (e.g. `db: demo-pg-hive`, the database
`hive` of the release `demo-pg`): it resolves to the output's values and
`secretRef`, and the consumer's release waits for the cluster's. A consumer of
another namespace (the platform's cluster lives in `cnpg-system`) claims a
database of its own (below), or references an **external connection**, a context
file (the platform's, its project's or its instance's `connections.yaml`)
carrying these values, whose `secretRef` names a Secret of the consumer's
namespace (here `creds-keycloak-db`, which the consumer's namespace holds: a claim's
Secret, or one External Secrets reads from the keys of that namespace in the platform's
secret store):

```yaml
connections:
  keycloak-db:
    contract: database-server
    engine: postgresql
    host: cnpg-system-cnpg-postgresql-rw.cnpg-system.svc.cluster.local
    port: 5432
    dbName: keycloak
    secretRef: {name: creds-keycloak-db}
```

The console's connection picker offers the outputs of the project's instances (their
`okdp.info.yaml`, no longer the descriptor ConfigMap `<release>-okdp`) and writes the
name of the selected one in the parameter.

## Provisioned connections: claims

`provisions: [database-server]`: a consumer whose connection reference takes
claims (`x-okdp-connection-ref`'s `provision: true`, airflow's `db`) claims a
database instead of naming one, and the compiler binds the claim to an instance
that provisions the contract: the one the claim names (`provider`), else the
provider of its class (`class`), else of the default class of the claimer's
context. The platform names this instance in its classes, as the sandbox does:

```yaml
# platform.yaml (level 0)
global:
  okdp:
    provisioning:
      database-server:
        default: standard
        classes:
          standard: {provider: cnpg-system/cnpg-postgresql}
    secrets:
      store: okdp-secrets   # the claimers are in other namespaces: see below
```

For each claim bound to the instance (`claims`, each `{id, contract, namespace,
name, request}`), in the cluster's namespace:

| Object | Name | |
|---|---|---|
| managed role (`Cluster` `spec.managed.roles`) | the claim's SQL name | login, its password from the credentials Secret |
| `Database` | the claim's ID | its SQL name, owned by the role, the extensions requested; `databaseReclaimPolicy: retain`, `helm.sh/resource-policy: keep` |
| credentials Secret | `<id>-credentials` | `username` (the role) and `password`, generated once by ESO (a `Password` generator and an `ExternalSecret`), `kubernetes.io/basic-auth`, labelled `cnpg.io/reload: "true"` and `okdp.io/credentials-database-server: "true"` |

The ID is the claim's, `<namespace>.<instance>.<field>` for a claim template
(`demo.airflow.db`, the instance `airflow` of the project `demo`) or
`<namespace>.<name>` for a named claim of a project (`demo.analytics`); its SQL
name, of the database and of the role, is the ID, each dash two underscores and
each dot one (`demo_airflow_db`, `demo.app-db` `demo_app__db`). A label of the ID
neither starts nor ends with a dash, so a dot is never next to one: two IDs never
give one SQL name (`team.a-db` `team_a__db`, `team-a.db` `team__a_db`, one name,
`team_a_db`, before). A SQL name longer than 62 characters (PostgreSQL takes 63),
or that is a database or an owner of `databases`, is its first 46 characters, `_`
and the ID's SHA-256 in hexadecimal, 63 characters: never a claim's SQL name of its
own, and a claim never fails the instance, which serves every other claim. Only a
SHA-256 prefix's collision, or a database of `databases` named as a hashed SQL name,
fails the compile (`cnpg-postgresql: the database and role <name> of a claim is
another claim's, ...`). A claim of an earlier version whose ID has a dash gets a
new database and role under its new SQL name; the former stays (reclaim policy
`retain`): move its data, then drop it by hand.

The claim's connection, an output named after its ID, is what its claimers
receive; they never name it:

```yaml
- name: demo.airflow.db
  contract: database-server
  values: {engine: postgresql, driver: org.postgresql.Driver, sslMode: prefer, port: 5432,
           host: cnpg-system-cnpg-postgresql-rw.cnpg-system.svc.cluster.local,
           dbName: demo_airflow_db, extensions: []}
  secretRef: {name: demo.airflow.db-credentials}
```

What a claim requests, the contract's claim schema (`x-okdp-claim` of
`contracts/database-server.schema.json`), its defaults applied:

- `extensions`: installed in the database by CloudNativePG's declarative
  extensions (`Database` `spec.extensions`, operator 1.26 or later; the sandbox
  runs 1.30), and published as granted. The contract allows those the cluster's
  image (`ghcr.io/cloudnative-pg/postgresql:18.3@sha256:5e30290f...`) ships that need no preloaded
  library: PostgreSQL's contrib (`btree_gin`, `btree_gist`, `citext`,
  `fuzzystrmatch`, `hstore`, `ltree`, `pg_trgm`, `pgcrypto`, `unaccent`,
  `uuid-ossp`) and pgvector (`vector`).
- `size`: accepted, not granted. PostgreSQL has no quota per database: all
  databases are on the cluster's volume (`storageSize`), and the connection
  publishes no `size`. A consumer that needs one requires it of the connection
  (`require`), and is refused here: its claim names a class whose provider
  grants sizes.

The data outlives the claim. When no instance claims it any more (the reference
removed, the named claim no longer declared), the compile drops the claim's
objects: Helm keeps the `Database` (`helm.sh/resource-policy: keep`),
CloudNativePG keeps the role (a role removed from `spec.managed.roles` is not
dropped), and the credentials Secret goes. A claimer that comes back, under the
same ID, finds its database, with a new password, which the role follows
(`cnpg.io/reload`). Drop a database by hand.

A claimer of another namespace gets the credentials through the platform's
secret store (`global.okdp.secrets.store`, the SecretStore of each namespace
the compiler writes from `global.okdp.secrets.provider`, else a
ClusterSecretStore of that name): the compiler writes a `PushSecret` in this
instance's objects, under the key `<namespace>/<id>` (this instance's
namespace), and an `ExternalSecret` in the claimer's,
`<release>-<id>-credentials`. Without the store, such a claim is refused. The
store's backend is the platform's: the sandbox's OpenBao, set up at bootstrap
(`bootstrap/openbao/`), each namespace reading and writing its own keys.

## Changes from the KuboCD package

- The connections were `kcd-<release>-<database>` with `secretRef: <name>`; they are
  `<release>-<database>` with `secretRef: {name}`, plus `driver` and `sslMode` defaults.
- `instances`, `storageSize` and `databaseReclaimPolicy` are parameters (were fixed:
  1 instance, 2Gi on class `standard`); the class comes from `global.okdp.storageClass.data`.
- The `Database` objects are named `<release>-<database>` (were `<database>`).
- The owner Secret is always external (the old chart could create it from `owner.password`,
  which the package never used).

## Tests

`ci/platform.yaml` holds the platform values of every case, without a storage
class. `sandbox` is the sandbox's component: its storage classes and the default
class of the platform (`ci/sandbox-platform.yaml`), no database of its own. `empty` and
`multi` are the databases of the values. `claims` is the provider
of the claims of the project `demo` (`ci/claims-project.yaml`), beside a
database of its values: the instance under test is the provider of the default
class (`ci/claims-platform.yaml`), and of the project's class `vector`, which
fixes the extensions of its claims; `analytics` is of the default class,
`embeddings` of the class `vector`, `reports` names its provider. The case
`collision` also holds the two claimer projects `a-b` and `a`
(`ci/collision-projects/`), whose instances `c` and `b-c` claim `a-b.c.db` and
`a.b-c.db` (and `a-db`), IDs a lossy mapping (dots and dashes both `_`) would
make one SQL name: they are `a__b_c_db` and `a_b__c_db`, two databases and two
roles. `bad-request`
must fail: a claim requests an extension the contract does not allow.
`name-clash`: a claim's SQL name is a database of the values, the claim's is hashed.
`collision`: the claims of two instances of the test claimer
`ci/catalog/database-claimer` of the repository, `demo.x.a-db` and `demo.x-a.db`,
one SQL name before, two now, and a named claim whose SQL name is hashed, too long
(`ci/collision-project.yaml`). Every case also compiles the platform's database
server of the repository's `ci/`.

Its cases, `ci/*-values.yaml`, compile by hand as the repository's
[README](../../../README.md#working-on-a-package) shows.
