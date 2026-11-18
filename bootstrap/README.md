# The sandbox's bootstrap

The prerequisites of the OKDP sandbox's platform
([`OKDP/okdp-sandbox`](https://github.com/OKDP/okdp-sandbox)): cert-manager,
ingress-nginx, the DNS, the tools, CloudNativePG, External Secrets, Keycloak, the S3
store, OpenBao, Forgejo and its CI runner. They are installed with Helm, each from its
upstream chart (the runner from [a chart of this directory](forgejo-runner)) with its
values of this directory, before anything compiled: no package of this catalog, OKDP
compiles none of them. The compiled platform reaches them through its settings and
connections (okdp-sandbox's `gitops/platform.yaml`); nothing of them is in the
deployments repositories, and the engine does not manage them: upgrade one with its
command again.

okdp-sandbox's `scripts/bootstrap.sh` runs the commands below, in this order (the
charts and versions of [`charts.yaml`](charts.yaml)), with this directory at the commit
of the catalog it reads (the `ref` of sandbox-charts in its `gitops/catalogs.yaml`).
By hand, run them from the root of a checkout of this repository, with `kubectl`
pointed at the cluster; they need `helm` (one that installs `oci://…@sha256:…`
references: 4.3 tested), `yq` v4, `jq` and `awk`, for the CoreDNS patch and OpenBao's
init. [`scripts/check-bootstrap.sh`](../scripts/check-bootstrap.sh) checks that these
commands name the releases of `charts.yaml` (CI:
[`bootstrap.yml`](../.github/workflows/bootstrap.yml)).

The installs are pinned to what was reviewed, as they run with cluster-admin: an OCI
chart is installed by the digest of its manifest (`oci://…@sha256:…`: the registry
serves that content or nothing), a chart of a repository by the sha256 of its package,
which `scripts/bootstrap.sh` checks (`helm pull`, then the install from the file)
before it installs it, as you would by hand (`helm pull cert-manager --repo
https://charts.jetstack.io --version v1.21.2`, then `sha256sum` against `sha256` in
[`charts.yaml`](charts.yaml)), and the images by digest in every values file
(`repository:tag@sha256:…`, or the chart's `digest`), the CI runner's okdp-gitops
image by the digest you give it (below). `scripts/check-bootstrap.sh --helm` fails on
a pin that is not what the registries serve, on a chart without one and on a rendered
image without a digest; [`scripts/bump-bootstrap.sh`](../scripts/bump-bootstrap.sh)
prints the current sha256, digests and the digests of the tags, to move them with a
version.

First the namespaces ([`namespaces.yaml`](namespaces.yaml)), each with its Pod
Security level: `baseline` enforced (no privileged container, no host namespace or
path), `restricted` warned and audited; `forgejo` alone `privileged`, for the CI
runner's Docker daemon (below), `baseline` warned; `argocd` and `flux-system`, where
the engines of okdp-sandbox's step 5 are installed, as the others. The releases'
`--create-namespace` find them.

The same file is the one list of the platform's own namespaces, by the label
`okdp.io/platform`: `"true"` for the bootstrap's, the engines' and the privileged
projects' (`global.okdp.policy.privileged` of the platform values, created here, the
compiled Namespace sets their Pod Security level), `system` for the cluster's own
(`kube-*`, `local-path-storage`). `okdp-ingress-hosts`, `okdp-external-name` (below)
leave out only those namespaces, and `okdp-platform` of approver-policy signs any name
for the ones labelled `"true"` alone; a namespace with no label, or another value, is
bound (`cnpg-system`, a confined project, has none). Only a cluster administrator
changes the label: `okdp-platform-label` (below) refuses everyone else.
okdp-sandbox's `scripts/check.sh` keeps it with the platform values: it fails on a
privileged project not labelled `"true"` here and on a confined project that is.
A project moved into `policy.privileged` needs the label (a `kubectl apply` of this
file) before its first sync, or the policies refuse its Ingress.
It is applied server-side, under a field manager of its own: a client-side apply
leaves the label in `last-applied`, which Argo CD's three-way merge removes from a
Namespace it also applies, and Flux takes over the fields of kubectl's managers;
`okdp-platform-label` would then refuse their sync.

```sh
kubectl apply --server-side --field-manager=okdp-bootstrap -f bootstrap/namespaces.yaml
kubectl apply -f bootstrap/network-policies.yaml
```

[`network-policies.yaml`](network-policies.yaml) is the default deny of the ingress of
the namespaces whose release brings no NetworkPolicy of its own (`cert-manager`,
`kube-tools`, `ingress-nginx`, `dns-server`, `cnpg-system`, `external-secrets`), with
the ports of their webhooks and services open to any source (Network policies,
below).

cert-manager, with its own approver off, then approver-policy, the only approver of
the certificate requests, and its policies
([`approver-policy/policies.yaml`](approver-policy/policies.yaml)): the CA of
`default-issuer`; the platform's own namespaces (labelled `okdp.io/platform=true`:
the bootstrap's, the engines', `global.okdp.policy.privileged`), any name; the other
namespaces, `dnsNames` and
`commonName` exactly `<label>.<namespace>.okdp.sandbox` (one DNS label, the namespace,
the suffix), no IP
address, no CA, so that `default-issuer` signs a project's own hosts only and
`keycloak.okdp.sandbox` is no project's to obtain; the issuers of a namespace
(`Issuer`), their own CA. A request no policy allows is denied; one for a
ClusterIssuer of your own waits for a policy of yours. trust-manager and the cluster
issuer `default-issuer`, a CA minted in the cluster (Secret
`cert-manager/default-issuer`, okdp-sandbox's
[step 7](https://github.com/OKDP/okdp-sandbox/blob/main/README.md#7-ssl-certificate)), the issuer of every
certificate; then the CA bundle, which trust-manager writes to every namespace
(Secret and ConfigMap `certs-bundle`, `global.okdp.tls.caBundleSecret`):

```sh
helm upgrade --install cert-manager cert-manager --repo https://charts.jetstack.io --version v1.21.2 \
  -n cert-manager --create-namespace --wait -f bootstrap/cert-manager/values.yaml
helm upgrade --install approver-policy cert-manager-approver-policy --repo https://charts.jetstack.io --version v0.29.0 \
  -n cert-manager --create-namespace --wait -f bootstrap/approver-policy/values.yaml
kubectl apply -f bootstrap/approver-policy/policies.yaml
helm upgrade --install trust-manager trust-manager --repo https://charts.jetstack.io --version v0.25.0 \
  -n cert-manager --create-namespace --wait -f bootstrap/trust-manager/values.yaml
helm upgrade --install cert-issuers oci://quay.io/okdp/charts/cert-issuers@sha256:b76c3386a1aa7d683b3db7c13a8e3a749073c4c965a4ae6a7dbbebdd46dabfa6 \
  -n cert-manager --create-namespace --wait -f bootstrap/cert-issuers/values.yaml
kubectl apply -f bootstrap/trust-manager/bundle.yaml
```

Reloader (a workload restarted when a Secret it mounts changes) and the admission
policies ([`policies.yaml`](protection/policies.yaml)): the deletion protection, three
ValidatingAdmissionPolicies that refuse to delete what is labelled
`okdp.io/protected=true` and the CRDs of the operators, and `okdp-pod-bounds`, the
bounds of the pods of a ServiceAccount that a ConfigMap of its namespace labelled
`okdp.io/pod-bounds=true` names (platform-charts' jupyterhub,
`<release>-spark-pod-bounds`, its PySpark sessions'): they run as that ServiceAccount,
read only the Secrets the ConfigMap lists (`secrets`), mount no `csi`, `flexVolume`,
`azureFile`, `cephfs`, `rbd` nor `iscsi` volume and no claim but those it names by
prefix (`pvcPrefixes`, none by default); the ServiceAccount changes or deletes only
the pods, services, configmaps and claims that carry its owner label (`ownerLabel`,
`spark-app-selector` by default: Spark's executors, their configmaps and claims),
never the images of a pod it updates, and writes no such ConfigMap; a namespace
without one is not bounded; and `okdp-ingress-hosts`
([`ingress-hosts.yaml`](protection/ingress-hosts.yaml)), the second line of the
compiler's rule on hosts: in a namespace that is not the platform's own, an Ingress
(rules and tls), a Certificate (`dnsNames`, `commonName`), a Gateway listener and the
annotations that name hosts serve only hosts `<label>.<namespace>.<suffix>`, one DNS
label, the namespace and the suffix, so that no namespace holds a host of another
(the suffix and the hosts listed per namespace are the ConfigMap
`kube-tools/okdp-ingress-hosts`, kept with the platform values; the namespaces left
out are those `namespaces.yaml` labels `okdp.io/platform`); no Ingress rule without
a host, no `spec.defaultBackend`
(ingress-nginx's catch-all) and no Gateway listener without a hostname; and
`okdp-external-name`, of the same file, no Service of type ExternalName in those
namespaces (the ingress controller would proxy to its name, past the NetworkPolicies;
`disable-svc-external-name` of `bootstrap/ingress-nginx` is the controller's half);
and `okdp-platform-label`, of `policies.yaml`, the guard of that label: a Namespace
created or updated with `okdp.io/platform` set, changed or removed, by anyone but a
cluster administrator (the groups `system:masters` and `kubeadm:cluster-admins`, the
identity of kubeadm's `admin.conf`), is refused, a tenant's or an engine's.
The policies are tested without a cluster:
[`protection/tests/`](protection/tests) holds, for each, the requests it must allow and
refuse (`scripts/check-bootstrap.sh` runs them with
[`scripts/policytest`](../scripts/policytest), a Go test that evaluates the policies
with the API server's own admission code, `k8s.io/apiserver`, and the matching it does
first; the CI too). No replicator: nothing copies a Secret
to other namespaces, which would let a namespace write into every other; what crosses
namespaces goes through the secret store (OpenBao, below), the CA bundle through
trust-manager:

```sh
helm upgrade --install reloader reloader --repo https://stakater.github.io/stakater-charts --version 2.2.17 \
  -n kube-tools --create-namespace --wait -f bootstrap/reloader/values.yaml
kubectl apply -f bootstrap/protection/policies.yaml
kubectl apply -f bootstrap/protection/ingress-hosts.yaml
```

ingress-nginx on the node ports kind maps to the host, the cluster's CoreDNS patched
to answer `*.okdp.sandbox` with the controller's Service (pods reach the services by
their public names, Keycloak first), and the host's DNS server (okdp-sandbox's [step 6](https://github.com/OKDP/okdp-sandbox/blob/main/README.md#6-dns-setup)).
That server answers `*.okdp.sandbox` with `127.0.0.1` to anyone, and forwards every
other name to the node's resolvers (Docker's DNS, the host's resolvers), never to a
public resolver, for the host and the kind network only (`acl`: the pods and
Services, `10.0.0.0/8`, are refused, they have the cluster's DNS); kind maps its node
port 30053 on the host's `127.0.0.1` only, the node port stays open to the kind
network and the pods. A host that sends it every name, not `okdp.sandbox` only,
loops back to it through the node's resolvers, and CoreDNS' `loop` plugin stops it:
route `okdp.sandbox` only to it (systemd-resolved's `Domains=~okdp.sandbox`,
dnsmasq's `server=/okdp.sandbox/`, macOS' `/etc/resolver/okdp.sandbox`), or forward
to other resolvers (`forward` of [`dns-server/values.yaml`](dns-server/values.yaml)):

```sh
helm upgrade --install ingress-nginx ingress-nginx --repo https://kubernetes.github.io/ingress-nginx --version 4.15.1 \
  -n ingress-nginx --create-namespace --wait -f bootstrap/ingress-nginx/values.yaml
bootstrap/coredns/patch.sh
helm upgrade --install dns-server coredns --repo https://coredns.github.io/helm --version 1.47.1 \
  -n dns-server --create-namespace --wait -f bootstrap/dns-server/values.yaml
```

The PostgreSQL operator, then External Secrets (the SecretStore of each project's
namespace is the compiler's, over the secret store installed below):

```sh
helm upgrade --install cloudnative-pg oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg@sha256:3245fa051bb21d0dd9246272f57a2760b4234817a164a3167d2a1e7fb9f63fd9 \
  -n cnpg-system --create-namespace --wait -f bootstrap/cloudnative-pg/values.yaml
helm upgrade --install external-secrets oci://ghcr.io/external-secrets/charts/external-secrets@sha256:1191874a26691d8377d8ba28bfae54a718dda4750e10d40ae9ae4d570c88acfd \
  -n external-secrets --create-namespace --wait -f bootstrap/external-secrets/values.yaml
```

Keycloak, on a PostgreSQL cluster of its own, with the realm of the sandbox, `okdp`
(the issuer `https://keycloak.okdp.sandbox/realms/okdp`): its users, roles and
clients, every application's and every person's, applied by keycloak-config-cli after
every install and upgrade ([`realm.yaml`](keycloak/realm.yaml)). The services
register their OAuth clients with initial access tokens (OpenBao's init mints them,
below); anonymous registration is refused (Keycloak's own policies), and the realm
adds two on authenticated registration (`components` of `realm.yaml`): every URL of a
registered client under `*.<domain>` (Trusted Hosts) and the user's consent (Consent
Required). Those policies are realm-wide, not per token: they cannot bind a redirect
URI to the namespace of the token that registers it, the compiler's check on its
redirect URIs is. The console's user management (client `okdp-control-plane`) manages the users
and groups of `okdp` only. The same client exchanges the console's tokens for the SQL editor's
statements on Trino (RFC 8693, standard token exchange, Keycloak 26.2 or later;
`token exchange` in the header of `realm.yaml`): a token of `okdp-ui` carries it in `aud`, and
it may request the audience `trino`, the value of the server's `SQL_TOKEN_EXCHANGE_AUDIENCE`. Its groups hold the people: `platform_admin`, the
platform's administrators (`global.okdp.access.admins` of okdp-sandbox's
`platform.yaml`: Argo CD's admin role, Forgejo's administrators and the
organization's owners), and `okdp-project-<namespace>` per project, its editors by
default (the project's Argo CD role and the namespace's `edit`, compiled from its
`project.yaml` `access`; the Forgejo team that writes its repository); tokens carry
them in the `groups` claim by name (full group path off), with the realm roles; the
service accounts hold their service's roles only (Trino's toward Polaris, `svc-trino-polaris-writer`:
`polaris_service_admin`, `polaris_catalog_admin`, not `platform_admin`). The realm `master` holds Keycloak's administrators only
(`masterRealm` of [`values.yaml`](keycloak/values.yaml)): its admin account, `admin`
(also keycloak-config-cli's and OpenBao's init's), comes from a Secret you create
first, `keycloak/keycloak-admin`, with a random password (key `admin-password`, once:
Keycloak sets it at its first start only, and the release does not own the Secret).
A sandbox installed when the realm was `master`: the upgrade creates `okdp` and
deletes from `master` the clients, roles and policies an import made there, not its
demo users (delete them in the admin console, or reinstall Keycloak: uninstall the
release, delete the cluster `keycloak-db` and its volumes, and install again); then
run OpenBao's init again (the initial access tokens of `okdp`) and push the layout
again (its issuer).
The realm holds no client secret:
[`client-secrets.sh`](keycloak/client-secrets.sh) first generates one per
client, 32 random bytes in hexadecimal, in Secret `keycloak/keycloak-client-secrets`
(once: run again, it keeps them and adds those of new clients), which
keycloak-config-cli reads into the realm (its variable substitution):

```sh
head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' | kubectl -n keycloak create secret generic \
  keycloak-admin --from-file=admin-password=/dev/stdin
kubectl apply -f bootstrap/keycloak/database.yaml
kubectl -n keycloak wait clusters.postgresql.cnpg.io/keycloak-db --for=condition=Ready --timeout=10m
bootstrap/keycloak/client-secrets.sh
helm upgrade --install keycloak keycloakx --repo https://codecentric.github.io/helm-charts --version 7.3.2 \
  -n keycloak --create-namespace --wait --timeout 15m \
  -f bootstrap/keycloak/values.yaml -f bootstrap/keycloak/realm.yaml
```

RustFS, the S3 store, as a company installs its own: its buckets (`okdp`, the bucket
of the platform's connection, and the demo's `lakehouse`, `bronze`, `silver`, `gold`)
an identity for the platform, its keys generated in the cluster (Secret
`rustfs/rustfs-okdp`), and the provisioning identity, generated the same way (Secret
`rustfs/rustfs-provisioner`), which creates the buckets, users and policies of the
claims (the package `s3-minio-provisioner`, through MinIO's admin API); its image,
the chart's appVersion, and its init container's by tag and digest:

```sh
helm upgrade --install rustfs rustfs --repo https://charts.rustfs.com --version 1.0.0 \
  -n rustfs --create-namespace --wait --timeout 15m -f bootstrap/rustfs/values.yaml
```

OpenBao, the platform's secret store (`global.okdp.secrets`), as a company installs
its own secret manager: one standalone server, on TLS only
(`https://openbao.openbao.svc.cluster.local:8200`: its certificate, Secret
`openbao/openbao-tls`, from a Certificate of the release issued by `default-issuer`;
its clients trust the CA bundle `certs-bundle`, key `ca.crt`, of their namespace),
then its init, which initializes and unseals it (**sandbox only**: one unseal key
share, kept in Secret `openbao/openbao-init`, the pod's sidecar unsealing it again at
every restart), enables the KV v2 mount `okdp` and the Kubernetes auth, writes the
policy `okdp`, templated on the namespace of the ServiceAccount that signs in, and the
role `okdp` (the policies are the HCL files of [`openbao/policies/`](openbao/policies),
`okdp-bootstrap.hcl` and `okdp.hcl`; the script only orchestrates; the helpers it shares
with Keycloak's `client-secrets.sh` are [`lib/common.sh`](lib/common.sh)) every ServiceAccount `okdp-secrets` may use with a token of audience
`openbao` (the compiler writes one per project, External Secrets requests the
tokens), and writes the credentials the platform gives, each under the keys of the
namespaces that use it only, never `platform/`, which no namespace reads (the policy
gives a namespace its own keys and its claims, nothing else): the platform's
identity of the S3 store (Secret `rustfs/rustfs-okdp`, `s3:*` on the platform's
buckets) under `<namespace>/s3/platform` of each namespace
[`s3.yaml`](openbao/s3.yaml) lists (`demo`, whose project's connection
`platform-s3` names that key; the other namespaces claim buckets of their own,
`s3-minio-provisioner`), a key `platform/s3` of an earlier init, which every
namespace read, deleted, and so is the key of a namespace removed from `s3.yaml`;
the provisioning identity of the S3 store
(Secret `rustfs/rustfs-provisioner`) under
`<S3_PROVISIONER_NAMESPACE>/s3-provisioner` (`s3-system` by default), and the secret
of a client of the realm (Secret `keycloak/keycloak-client-secrets`) under
`<namespace>/keycloak/<client>` (property `client_secret`) of each namespace that
reads it, as [`clients.yaml`](openbao/clients.yaml) lists them (`okdp-control-plane`
in `okdp-system`, the services' clients in `demo`), which the Secrets of the compiled
instances there read (`okdp-system/local-secrets-provider`, `demo/secrets`); a client
it does not list is not written (`forgejo`: Forgejo reads
`keycloak/keycloak-client-secrets` itself). Run it again after adding a client to the
realm or to `clients.yaml`, or a namespace to `s3.yaml`; it deletes the keys
`platform/keycloak/<client>` an earlier init wrote. No root token remains: the first
init revokes its own once the role `okdp-bootstrap` works, and every run signs in as the ServiceAccount
`openbao/okdp-bootstrap` of the release (`kubectl create token`, audience `openbao`),
whose policy writes what the init writes and reads none of the keys but the custom
metadata of the DCR tokens'; a sandbox of an earlier init has its root token revoked,
and removed from `openbao-init`, at the next run. The unseal key in `openbao-init` is
root-equivalent: whoever reads that Secret runs `bao operator generate-root` with it,
no token needed, and reads and writes every credential (the way back in, too, if
the role `okdp-bootstrap` is lost). With `DCR_NAMESPACES` (space-separated project
namespaces, validated like the others, not `platform`) it also mints an initial
access token of the realm `okdp` per namespace for dynamic client registration, at
`<namespace>/keycloak/dcr-token`: only when the key is absent, or its token (the
`iat-id` of the key's custom metadata) is gone from Keycloak, used up
(`DCR_TOKEN_COUNT`, 10 registrations) or within a day of its end
(`DCR_TOKEN_EXPIRATION`, 30 days by default, never with 0); the key keeps one
version, and the token it replaces is deleted from Keycloak. The Keycloak admin's
password reaches `kcadm.sh` through `KC_CLI_PASSWORD`, read from the exec's standard input, on no command line:

```sh
helm upgrade --install openbao openbao --repo https://openbao.github.io/openbao-helm --version 0.30.4 \
  -n openbao --create-namespace --wait -f bootstrap/openbao/values.yaml
bootstrap/openbao/init.sh
```

Forgejo holds the deployments repositories, the compiled tree among them, and the
service catalogs: the engine reads the output (as `okdp-reader`), the CI writes it
(as `okdp-ci`, its only pusher), the console writes the sources (as `okdp-console`),
three accounts, none an admin, that okdp-sandbox's
[step 4](https://github.com/OKDP/okdp-sandbox/blob/main/README.md#4-put-the-repositories-on-forgejo) creates. Its admin account
comes from a Secret you create first, with a random password:

```sh
head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' | kubectl -n forgejo create secret generic \
  okdp-forgejo-admin --from-literal=username=okdp-admin --from-file=password=/dev/stdin
helm upgrade --install forgejo oci://code.forgejo.org/forgejo-helm/forgejo@sha256:f5044e73361f5991978f1bc281a570bf893fd0f468e7d76274a7853eb27428cf \
  -n forgejo --create-namespace --wait -f bootstrap/forgejo/values.yaml
```

The CI runner of the deployments repositories, a Forgejo Actions runner whose Docker
daemon (docker-in-docker) runs each compile in a new container of the okdp-gitops
image (its values: the image, `okdp-registry:5000/okdp-gitops:dev` by default, the
sandbox's own build in the registry of the kind network, okdp-sandbox's
[step 2](https://github.com/OKDP/okdp-sandbox/blob/main/README.md#2-create-the-kind-cluster),
**by digest**: the chart refuses to render without `okdpGitopsImage.digest`, as the
image receives the output repository's write token and a tag is mutable; the runner's
and the daemon's images by tag and digest); its pod starts once okdp-sandbox's
[step 4](https://github.com/OKDP/okdp-sandbox/blob/main/README.md#4-put-the-repositories-on-forgejo) registers it.
The daemon is rootless (`docker:<version>-dind-rootless`): no root, no privileged
container, the pod in a user namespace of its own (`hostUsers: false`, Kubernetes
1.33 or later), its jobs' users the pod's unprivileged IDs, their network
slirp4netns', user-mode, out of the pod's address (its NetworkPolicy applies to
them). The Forgejo runner has no Kubernetes backend (docker, host, lxc), and a host
job would share the runner's container and its registration secret: a daemon it is.
What the daemon still needs of the node keeps `forgejo` `privileged`, as `baseline`
refuses each: seccomp `Unconfined` (the user namespaces of the daemon and of its
containers: `RuntimeDefault` refuses them without `CAP_SYS_ADMIN`), `/proc`
unmasked (`procMount: Unmasked`, its containers mount their own), the node's
`/dev/net/tun` (a `hostPath`, slirp4netns' TAP device), AppArmor unconfined on a
node that has it (its default profile refuses mount; on Ubuntu 23.10 or later,
the node's `kernel.apparmor_restrict_unprivileged_userns=0` too), and its privilege
escalation (`newuidmap`, `newgidmap`: of capabilities `SETUID` and `SETGID`, the
container's only ones):

```sh
helm upgrade --install forgejo-runner bootstrap/forgejo-runner -n forgejo \
  -f bootstrap/forgejo-runner/values.yaml --set okdpGitopsImage.digest=sha256:<digest>
```

Their ingresses (`keycloak`, `s3`, `s3-console`, `forgejo` `.okdp.sandbox`) are served
by the ingress controller installed first. Keycloak's serves the realm `okdp`, the
static resources and the admin API of the realm `okdp` only (the console's user and
group management), not the admin console nor the realm `master`, which are
Keycloak's at `http://localhost:8080` (`adminUrl` of
[`keycloak/values.yaml`](keycloak/values.yaml): `KC_HOSTNAME_ADMIN` and the frontend
URL of `master`), through a port-forward from the host:
`kubectl -n keycloak port-forward svc/keycloak-http 8080:80`, then
`http://localhost:8080/admin/`. The
Keycloak admin's password, for its admin console (user `admin`):
`kubectl -n keycloak get secret keycloak-admin -o jsonpath='{.data.admin-password}' | base64 -d`;
the Forgejo admin's password, for its web UI:
`kubectl -n forgejo get secret okdp-forgejo-admin -o jsonpath='{.data.password}' | base64 -d`;
RustFS' root, for its console:
`kubectl -n rustfs get secret rustfs-root -o jsonpath='{.data.RUSTFS_SECRET_KEY}' | base64 -d`
(user `okdp-root`); a client's secret:
`kubectl -n keycloak get secret keycloak-client-secrets -o jsonpath='{.data.<client>}' | base64 -d`;
the names of OpenBao's keys, signed in as `okdp-bootstrap` (its token given to `bao`
in the pod on its standard input, revoked after; that identity lists the keys and
reads none: their values are those of the Secrets above, the platform signs in as the
ServiceAccount of each namespace):

```sh
kubectl -n openbao create token okdp-bootstrap --audience openbao --duration 10m \
  | kubectl -n openbao exec -i openbao-0 -c openbao -- sh -c \
    'BAO_TOKEN="$(bao write -field=token auth/kubernetes/login role=okdp-bootstrap jwt=-)" && export BAO_TOKEN
     bao kv list okdp/; bao token revoke -self >/dev/null'
```

A sandbox installed before the dependencies left the compiled tree is reinstalled:
delete the cluster (okdp-sandbox's [Cleanup](https://github.com/OKDP/okdp-sandbox/blob/main/README.md#cleanup)) and start again.
So is one whose Keycloak release held the admin password `admin` (its values'
`secrets.admin`, the Secret `keycloak-admin` the release owned): an upgrade deletes
that Secret, and Keycloak keeps the password of its first start.
One of an earlier bootstrap also runs kubernetes-replicator, which this one no longer
installs: `helm -n kube-tools uninstall kubernetes-replicator` stops it, but the
copies it made stay in every namespace, a reason more to start again.

## Network policies

The releases bring their namespaces' NetworkPolicies, and `network-policies.yaml` those
of the namespaces whose release brings none: what is not listed is refused (a default
deny of the ingress in each, the CI runner's egress besides). The kubelet's
probes come from the node, which a NetworkPolicy always lets in; `kubectl exec` and
`port-forward` do not go through the pods' network.

| Namespace (release) | Reaches it | Port |
|---|---|---|
| `openbao` | External Secrets' controller (`external-secrets`), the store's only client | 8200 (TLS) |
| `keycloak` | the ingress controller (`ingress-nginx`): the browsers and the in-cluster OIDC clients, which reach `keycloak.<domain>` through it (the CoreDNS patch) | 8080 |
| | the namespace's own pods (keycloak-config-cli, the database) | all |
| | the CloudNativePG operator (`cnpg-system`), to the database | 8000, 5432 |
| `rustfs` | every namespace (the projects' services, the claims' provisioner) | 9000 (S3) |
| | the ingress controller | 9001 (console) |
| `forgejo` | the ingress controller, the engines (`argocd`, `flux-system`), the console (`okdp-system`), the CI runner | 3000 |
| `cert-manager` (+ trust-manager) | any source: the API server (the webhooks) and the pods that check them | 10250, 6443 (webhooks) |
| `ingress-nginx` | any source: the browsers, the pods that reach `<host>.<domain>` through it (its admission webhook is off, no 8443) | 80, 443 |
| `dns-server` | any source: the host and the kind network (the server's `acl` bounds who is answered) | 53 (UDP, TCP) |
| `cnpg-system` | any source: the API server (the webhooks) | 9443 |
| `external-secrets` | any source: the API server (the webhook) | 10250 |
| `kube-tools` | nobody (Reloader listens for no one) | none |

The webhooks' and services' ports of these six namespaces are open to any source, not
to the API server only: it runs on the host network of the control-plane nodes, whose
addresses (a node's, the pod network's gateway) differ from one cluster to the next and
cannot be named in a NetworkPolicy; their metrics, health and controller ports are
closed to the other pods.

The CI runner (`forgejo/forgejo-runner`, its jobs' containers too) reaches the
cluster's DNS, Forgejo's port 3000 (the runner's registration) and the ingress controller's 443 (the
jobs reach Forgejo at `https://forgejo.<domain>`, `networkPolicy.ingress`), the registries of its values' `networkPolicy.registries`
(`okdp-registry:5000`, a container of the kind network, `172.18.0.0/16`) and the
internet on 443 (the chart repositories, the catalogs, the image registries), not
the private ranges: none of the cluster's other services (OpenBao, Keycloak, RustFS,
the API server). The jobs trust the platform's CA bundle (`certs-bundle`, mounted
read-only in the Docker daemon's container, `caBundle` of the runner's values, and
in the job by the workflow, `SSL_CERT_FILE`), so that the CI's token never goes
over `http://`; a proxy of a private range goes in `networkPolicy.extraEgress`.
The management port of Keycloak (9000) is reached from its namespace only; its
`/admin` stays on the ingress (a path is the ingress controller's to refuse, L7, not
a NetworkPolicy's). Another namespace of an engine or of the console: add it to
the list of `forgejo/values.yaml`.

A NetworkPolicy is enforced by the cluster's network plugin, not by the API: a
plugin that does not (flannel alone) ignores them, and every pod reaches every
service. okdp-sandbox's clusters (`scripts/e2e-kind.sh`, its README's step 2) run
kind's default plugin, kindnet, which enforces them in the kind releases of the
last years (0.24 and later: kube-network-policies, its ClusterRole watches the
NetworkPolicies; the node image `kindest/node:v1.37.0` runs kindnetd
`v20260820`); an older kind needs Calico or Cilium (`networking.disableDefaultCNI`
in the kind configuration, then the plugin).

## Accepted risks

Two things of the bootstrap are known and kept, for the sandbox:

- **`forgejo` is at Pod Security `privileged`.** The CI runner's Docker daemon is
  rootless and no container is privileged, but it needs what `baseline` refuses
  (seccomp and AppArmor `Unconfined`, `/proc` unmasked, the node's `/dev/net/tun`), and
  it shares the namespace with Forgejo. Hosts without `/dev/net/tun`, and Ubuntu 23.10
  or later (`kernel.apparmor_restrict_unprivileged_userns=0`), need extra steps. Only
  the runner's pod, with the okdp-gitops image by digest and its egress bounded
  (Network policies), runs there.
- **The console's Keycloak client can administer the people of the realm `okdp`.**
  `okdp-control-plane` holds `manage-users` (and the view and query roles) on the realm
  `okdp` only, not `master`: whoever holds it adds anyone to `platform_admin`, so the
  control plane's server is as trusted as the platform's administrators, and a
  compromise of the server is a compromise of the platform. The control plane is
  optional; without it no client holds the role.
