[![Release](https://img.shields.io/github/v/release/okdp/sandbox-charts)](https://github.com/okdp/sandbox-charts/releases/latest)&ensp;&ensp;
[![Helm](https://img.shields.io/badge/helm-3%20%7C%204-blue.svg)](https://helm.sh/)&ensp;&ensp;
[![Kubernetes](https://img.shields.io/badge/kubernetes-1.30+-blue.svg)](https://kubernetes.io/)&ensp;&ensp;
[![License Apache2](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](http://www.apache.org/licenses/LICENSE-2.0)
<a href="https://okdp.io">
<img src="https://okdp.io/logos/okdp-notext.svg" height="20px" style="margin: 0 2px;" />
</a>

## Overview

This repository holds the OKDP packages of the sandbox's own platform services: its
database server (`cnpg-postgresql`, the provider of the claims of databases), its
Secrets of generated or stored credentials (`local-secrets-provider`), the provider of
the claims of buckets on an S3 store OKDP does not deploy (`s3-minio-provisioner`,
MinIO's admin API: the sandbox's RustFS) and an optional object store (`seaweedfs`,
which provisions the claims of buckets on itself). They are not part of the OKDP
distribution itself.

The platform's prerequisites are no packages: cert-manager and the CA bundle, the
ingress controller, the DNS, the tools (Reloader, the admission policies), the
operators (CloudNativePG, External Secrets), the identity provider (Keycloak), the S3
store (RustFS), the secret store (OpenBao), Forgejo and its CI runner are installed with helm before anything compiled: their values, manifests
and init scripts are this repository's [`bootstrap/`](bootstrap) (its
[README](bootstrap/README.md) lists the commands), which `OKDP/okdp-sandbox`'s
`scripts/bootstrap.sh` installs, at the commit of this catalog the sandbox reads. What
the services need of them is a platform setting or a connection,
which a cluster's own fill as well: `global.okdp.ingress` (`suffix`, `className`),
`global.okdp.tls` (`clusterIssuer`, the ClusterIssuer of the services' certificates;
`caBundleSecret`, the Secret of each namespace holding the CA bundle, `ca.crt` and
`bundle.p12`, as a trust-manager Bundle writes one), `global.okdp.oidc`, an `s3`
connection of `platform.yaml`.

It is a **catalog** of OKDP services, as
[`OKDP/platform-charts`](https://github.com/OKDP/platform-charts): one package per
service version, in the format of [`okdp-compile`](https://github.com/OKDP/okdp-compiler),
which compiles the values of an instance into the values of each upstream chart the
service is made of, OKDP's own objects and what the instance publishes. The upstream
charts are rendered as published, from their own repositories: nothing of this
repository is published as a chart, everything OKDP stays in Git.

A platform reads the catalog from Git: the `catalogs.yaml` of its deployments
repository, beside `platform.yaml`, lists the catalog repositories (`repositories:
[{name: sandbox-charts, url: <git url>, ref: <branch|tag|commit>}]`), and the versions
of a service are the `catalog/<service>/<version>/` directories found at `ref`. The
sandbox's deployments repository, read by Flux or Argo CD, is
[`OKDP/okdp-sandbox`](https://github.com/OKDP/okdp-sandbox). What it deploys from here,
as instances of okdp-compiler's tree, and what the platform must provide first, are in
[`docs/deploying.md`](./docs/deploying.md).

## Structure

```
catalog/<service>/<version>/   one package version, immutable once released
contracts/                     the contracts the packages provide or consume (<contract>.schema.json)
scripts/check-shared.sh        diffs the files the catalogs share with other catalogs checked out beside this one
ci/                            what every test case is compiled with: platform values (ci/platform.yaml),
                               the providers of the claims (ci/projects/), test packages never
                               deployed (ci/catalog/: the claimers of databases and buckets), not packages
docs/deploying.md              deploying these services: the sandbox's instances, the platform's needs
```

The `version` is `<upstream version>-<OKDP version>`. Each service's README documents its
parameters, its known gaps and, for a service the former KuboCD catalog had, what
changed from that package.

| Service | Version | Upstream charts | Description |
| --- | --- | --- | --- |
| [`cnpg-postgresql`](./catalog/cnpg-postgresql/18.3.0-1.0.0) | `18.3.0-1.0.0` | none: OKDP's own objects | PostgreSQL cluster (CloudNativePG) with logical databases, one `database-server` output each; provisions `database-server` connections, a database per claim |
| [`local-secrets-provider`](./catalog/local-secrets-provider/1.0.0-1.0.0) | `1.0.0-1.0.0` | none: OKDP's own objects | Secrets whose credentials External Secrets Operator generates in the cluster or reads from the keys of its namespace in the platform's secret store, in the instance's namespace only, a local stand-in for a secret manager |
| [`s3-minio-provisioner`](./catalog/s3-minio-provisioner/1.0.0-1.0.0) | `1.0.0-1.0.0` | none: OKDP's own objects | Provisions `s3` connections on an external S3 store through MinIO's admin API (MinIO, RustFS): a bucket, an identity limited to it and the requested prefixes per claim, by a Job using Node's standard library (no `mc`); deploys no store |
| [`seaweedfs`](./catalog/seaweedfs/4.47.0-1.0.0) | `4.47.0-1.0.0` | `seaweedfs` 4.47.0 (seaweedfs.github.io) | SeaweedFS object store (S3, IAM, STS); one `s3` output; provisions `s3` connections, a bucket and its identity per claim; optional: an external store serves as well (an `s3` connection of the platform), the sandbox's S3 store is installed with helm |

The operators the platform depends on, CloudNativePG and External Secrets, and the
other prerequisites are not packages: they are installed with helm, before anything
compiled ([`docs/deploying.md`](./docs/deploying.md)).

A package (`catalog/<service>/<version>/`, laid out as a Helm umbrella chart over its
upstream charts, never packaged):

```
Chart.yaml                 name: <service>, version: <version>, dependencies: the upstream charts,
                           each pinned in its own repository (none for a package of objects only)
okdp.yaml                  OKDP's part: roles and dependsOn (catalog metadata), require (platform
                           values), defaults, upstream (what an instance may set: protect, append),
                           provisions (the contracts it provisions a connection of per claim),
                           then vars, errors, objects (OKDP's own objects), instance (URL, usage),
                           provides (connections published), oidcClients (OAuth clients)
values.cel.yaml            the values of each upstream chart, by dependency key, YAML + CEL
<key>.defaults.yaml        OKDP's defaults of the chart <key>, plain YAML
config.schema.json         the parameters: types, defaults, x-ui-* hints, x-okdp-connection-ref
README.md                  parameters, platform values read, charts, known gaps
ci/<case>-values.yaml      test instances (a first line "# error: <message>": a case that must fail)
ci/platform.yaml           the platform values of the cases (global.okdp), when they share them
ci/<case>-platform.yaml    a case's own platform values
ci/<case>-project.yaml     a case's project file: its named claims, classes, connections
ci/<case>-connections.yaml a case's own connections
ci/<case>-instances/       other instances of a case's project, whose outputs it references
ci/<case>-projects/        other projects of a case's tree (project.yaml, instances/): the claimers of
                           other namespaces of a provider, with the claimer test packages of ci/catalog/
```

The format is described in [`okdp-compiler`](https://github.com/OKDP/okdp-compiler):
[writing a package](https://github.com/OKDP/okdp-compiler/blob/main/docs/02_writing_package.md),
[the service definition](https://github.com/OKDP/okdp-compiler/blob/main/docs/specs/02_service_definition.md),
[inputs and outputs](https://github.com/OKDP/okdp-compiler/blob/main/docs/specs/01_inputs_outputs.md).

## OKDP services

Every service follows the OKDP rules (shared with `platform-charts`):

- the context, by level: the platform values (`global.okdp`, the classes of the
  claims among them) and the platform's connections, a project's (its classes,
  connections and named claims), an instance's own connections; then the
  instance's values, its parameters and its upstream values (`upstream.<key>`,
  except the paths the package protects);
- each upstream chart receives, merged in this order: its own defaults (Helm applies
  them), OKDP's defaults (`<key>.defaults.yaml`), the values the mapping computes
  (`values.cel.yaml`), and the instance's upstream values;
- OKDP's own objects (generated Secrets, hooks, custom resources, the RBAC and
  Jobs of OKDP's own components) are the package's `objects`: the compiled
  umbrella renders them from `okdp.objects.yaml`, as written. What an instance
  publishes (URL, usage, provided connections) is `okdp.info.yaml`, beside the
  compiled umbrella (it replaces the descriptor ConfigMap `<release>-okdp`). A
  provider publishes its connections, each named; an instance of the same
  namespace references one by its name, and waits for its provider;
- a consumer may claim a connection instead (a reference with `provision: true`,
  a claim by default where the package says so: airflow's database, a package
  of `OKDP/platform-charts`), which the
  instance that provisions its contract creates for it (`provisions`:
  cnpg-postgresql a database, s3-minio-provisioner a bucket on an external
  store, seaweedfs a bucket on its own): the provider of
  its class, of the platform's classes (`global.okdp.provisioning.<contract>`, a
  default class and the classes by name) or of its project's, or the one it
  names. The credentials of a claim of another namespace cross through the
  platform's secret store (`global.okdp.secrets.store`: with
  `global.okdp.secrets.provider`, the sandbox's OpenBao, a SecretStore of that
  name in each project's namespace, which the compiler writes, each namespace
  its own identity; the bootstrap creates none). A connection that
  is neither an output nor a claim is declared in a context file
  (`connections`);
- the text fields of a contract (URLs, hosts, regions, names, the items of
  its lists) refuse a carriage return and a line feed (`pattern:
  ^[^\r\n]*$`), as packages write a connection's values into configuration
  files, where a second line would be a setting of its own. The compiler
  refuses such a connection whoever declared it, a context file or a
  claim's provider; a new text field of a contract takes the same pattern
  (secrets, `enum` and fields with their own `pattern` excepted). The cases
  `newline-*` of cnpg-postgresql and s3-minio-provisioner show the refusals;
- a compile is deterministic: generated passwords come from External Secrets Operator
  generators, and nothing differs between `helm install` (Flux) and `helm template`
  (Argo CD): upstream features built on `lookup`, random functions, `genCA` or
  `.Capabilities` are kept off, their switches protected.

## Migration from KuboCD

The packages of this catalog replace the KuboCD packages of the same services.
What moved, for someone coming from the KuboCD modules:

| KuboCD | Here |
|---|---|
| A package built and pushed to a registry, one chart per module | A directory `catalog/<service>/<version>/`, read from Git through `catalogs.yaml`: nothing is built, pushed or pulled but the upstream charts |
| The modules (`main`, `auth-config`, `provisioning`), OKDP's wrapper charts | The upstream chart of `Chart.yaml`, rendered as published (seaweedfs), and OKDP's own objects, the `objects` of `okdp.yaml` (the ESO configuration of `auth-config`, the Job of `provisioning`, the templates of the cnpg-postgresql chart). A vendored chart patched for Helm or Argo CD is a protected value or an object |
| `{{ .Parameters }}` and `{{ .Context }}` templates | `${{ ... }}` CEL in `values.cel.yaml` and `okdp.yaml`, over `values` (the parameters of `config.schema.json`), `global.okdp` (the platform) and the references. A `{{` in an instance value is refused |
| The context and the endpoints of a role (`{{ storage.endpoints.apiUrl }}`) | The platform's values `global.okdp` and the connections of `contracts/`: a reference parameter names a connection (an output of another instance, a claim, or one declared in a context file). seaweedfs' output is `s3`, cnpg-postgresql's `database-server` (`<release>-<database>`, were `kcd-<release>-<database>`) |
| A release of a package, in a namespace | An instance of a project: the release `<project>-<instance>`, in the project's namespace; the objects' names no longer carry a module suffix |
| Credentials in the values, drawn with `lookup` and `randAlphaNum` | Generated in the cluster by External Secrets Operator (`okdpGeneratedSecret`) or read from the platform's secret store, never a value in Git: local-secrets-provider's entries, seaweedfs' root keys |
| The prerequisites as packages (cert-manager, ingress, tools, keycloak, the operators) | No packages: installed with helm by [`bootstrap/`](bootstrap) before anything compiled, read by the services as platform settings (`global.okdp`) |

Each service's README says what changed from its KuboCD package.
`roles` and `dependsOn` of `okdp.yaml` are kept as catalog metadata: the
compiler does not read them, and the order a deployer applies the instances in
comes from the references between them. `roles` names what a service gives
the platform: `storage` (seaweedfs, s3-minio-provisioner), `database-server`
(cnpg-postgresql) and `external-secrets` (local-secrets-provider: Secrets
generated or read through ESO). A role no package provides is the platform's
own, installed by the bootstrap or the cluster: `ingress` (the ingress
controller), `pg-operator` (CloudNativePG) and, as a need,
`external-secrets` (External Secrets Operator itself).

## Working on a package

`okdp-compile` compiles trees: the catalog, a platform's values, projects and
their instances, every instance of the tree together (`okdp-compile --repository
<dir>...`, each catalog a `--catalog <dir>`). A test case is such a tree: this
repository, a catalog (`catalog/`, `contracts/` only: `okdp-compile` refuses a
catalog that holds `platform.yaml` or `projects/`) and a test tree of the case, `platform.yaml`, the project `demo`
and its instance `<service>` (the release `demo-<service>`), `config.yaml` the
case's values, beside the providers of its claims (`ci/` of the repository:
the platform's database server, `cnpg-system/cnpg-postgresql`).

```bash
export OKDP_CHARTS=~/.cache/okdp/charts     # the chart cache of the checks (helm pull --untar)
pkg=catalog/seaweedfs/4.47.0-1.0.0

# a test case, compiled by hand: the case no-oidc of seaweedfs
t=$(mktemp -d) && mkdir -p $t/projects/demo/instances/seaweedfs
yq eval-all '. as $l ireduce ({}; . * $l)' ci/platform.yaml $pkg/ci/platform.yaml \
  $pkg/ci/no-oidc-platform.yaml > $t/platform.yaml
cp -R ci/projects $t/
printf 'service: seaweedfs\nversion: 4.47.0-1.0.0\n' > $t/projects/demo/instances/seaweedfs/instance.yaml
cp $pkg/ci/no-oidc-values.yaml $t/projects/demo/instances/seaweedfs/config.yaml
okdp-compile --catalog . --repository $t -o /tmp/tree           # every instance of the tree
okdp-compile --catalog . --repository $t --check --charts $OKDP_CHARTS   # against the upstream charts

# render the case's instance as a deployment does
i=/tmp/tree/projects/demo/instances/demo-seaweedfs
chart=$(mktemp -d) && cp -R $i/. "$chart" && helm dependency build "$chart"
helm template demo-seaweedfs "$chart" -n demo -f $i/instance.values.yaml
```

The cases compile by hand, with okdp-gitops' `okdp-compile`, `helm` and
`yq`; no workflow compiles them. A case's render may hold no object that
the deployer of a project, confined to its namespace, refuses at sync (of
a cluster-scoped kind, ClusterRole, CustomResourceDefinition, a webhook
configuration..., or of another namespace), unless its platform values
make its project, `demo`, privileged: an operator's package, or the
control plane's, gives `global.okdp.policy.privileged: [demo]` in its
`ci/platform.yaml`.

The files the OKDP catalog repositories share are byte-identical in each:
`scripts/check-shared.sh`, `LICENSE`, the workflows `release-please.yml`
and `conventional-commits.yml` of `.github/workflows/`, and the contracts
several catalogs hold (a tree reads the contracts of all its catalogs, and
the compiler refuses two of one name that differ). `OKDP/platform-charts`
holds the canonical copies: a change is made there and copied to every
catalog in the same pass. CI cannot check it, no catalog reading another:
`scripts/check-shared.sh ../platform-charts ../community-charts`, the
catalogs checked out side by side, diffs them.

A package names its images by digest (`repository:tag@sha256:...`), a package
that pulls from a registry a tag can move in is not accepted. Look the digest of a tag up
with `crane digest <repository>:<tag>` (or `skopeo inspect --format '{{.Digest}}'
docker://<repository>:<tag>`; both read the registry only), and say it in the package's
README; the bootstrap's images are pinned the same way (`scripts/bump-bootstrap.sh`).

A released version directory is immutable: a change of a service is a new version, a
copy of the directory under its new version (`Chart.yaml` `version`). The upstream half
of the version follows the main upstream chart, the OKDP half is SemVer of the package.

## CI and releases

No workflow compiles the packages: their test cases compile by hand
([Working on a package](#working-on-a-package)). Nothing is published.
[`bootstrap.yml`](.github/workflows/bootstrap.yml), this repository's own, runs
`scripts/check-bootstrap.sh --helm` on each change of `bootstrap/`: its YAML, the
commands of `bootstrap/README.md` against `bootstrap/charts.yaml`, the pins of the
charts (sha256, digest) against their repositories and registries, `helm template`
of each release with its values, no image without a digest, and the CEL admission
policies of `bootstrap/protection` against the allowed and refused requests of
`bootstrap/protection/tests` (`scripts/policytest`, a Go test, no cluster).

[`release-please.yml`](.github/workflows/release-please.yml) releases the repository as
a whole: merging its release pull request tags `vX.Y.Z` and updates `CHANGELOG.md`, a ref
a platform's `catalogs.yaml` can pin.

---

## Contributing & License

Contributions follow the [OKDP contribution guide](https://github.com/OKDP/.github/blob/main/CONTRIBUTING.md). Released under the [Apache License 2.0](LICENSE).

---

**Built 🚀 for the OKDP Community**
<a href="https://okdp.io">
  <img src="https://okdp.io/logos/okdp-notext.svg" height="20px" style="margin: 0 2px;" />
</a>
