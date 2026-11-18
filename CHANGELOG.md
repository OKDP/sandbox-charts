# Changelog

## [2.0.0](https://github.com/OKDP/sandbox-charts/compare/v1.0.0...v2.0.0) (2026-11-18)


### ⚠ BREAKING CHANGES

* **seaweedfs:** provider of s3 claims, the filer UI behind a sign-in proxy, images by digest
* **cnpg-postgresql:** provider of database-server claims, the image by digest
* **local-secrets-provider:** credentials generated in the cluster, a Secret stays in its namespace
* the platform prerequisites removed from the catalog, the repository renamed sandbox-charts
* **seaweedfs:** catalog/seaweedfs/4.47.0-1.0.0
* **keycloak:** catalog/keycloak/7.3.2-1.0.0, its database a connection of the context
* **cnpg-postgresql:** catalog/cnpg-postgresql/18.3.0-1.0.0, a package of OKDP objects only
* **ingress-nginx:** catalog/ingress-nginx/4.15.1-1.0.0
* **vault:** catalog/vault/0.34.1-1.0.0
* **local-secrets-provider:** catalog/local-secrets-provider/1.0.0-1.0.0, its Secrets among OKDP objects
* **coredns-patch:** catalog/coredns-patch/1.0.0-1.0.0, its RBAC among OKDP objects
* **dns-server:** catalog/dns-server/1.47.1-1.0.0
* **tools:** catalog/tools/1.0.0-1.0.0
* **cert-manager:** catalog/cert-manager/1.21.2-1.0.0, the Bundle CRD installed with trust-manager
* an okdp-compiler catalog: contracts, compile-charts.sh, CI and repository releases, nothing published; cloudnative-pg and external-secrets from upstream, no kubauth nor kubocd-webhooks

### Features

* added conventional commit guard rails ([622293a](https://github.com/OKDP/sandbox-charts/commit/622293a2e96797b02cb73ff3dc7dc1c7166df479))
* an okdp-compiler catalog: contracts, compile-charts.sh, CI and repository releases, nothing published; cloudnative-pg and external-secrets from upstream, no kubauth nor kubocd-webhooks ([8d98e02](https://github.com/OKDP/sandbox-charts/commit/8d98e02b3aa5ec95802b3429d8898dbbb912f872))
* **bootstrap:** CoreDNS patch, dns-server, ingress-nginx, external-secrets, cloudnative-pg and reloader ([63e88cd](https://github.com/OKDP/sandbox-charts/commit/63e88cd087cd948913f184382bdd356bba56c53c))
* **bootstrap:** Keycloak, the realm okdp and its client secrets ([14d7b77](https://github.com/OKDP/sandbox-charts/commit/14d7b772e6f30e0d94feecb1c45b218ebcccb56c))
* **bootstrap:** namespaces, pinned charts, cert-manager, trust-manager, the issuers and approver-policy ([299dc76](https://github.com/OKDP/sandbox-charts/commit/299dc76b7743312e32145abc587453fe6752158b))
* **bootstrap:** network policies and the admission policies, with their tests ([acb305b](https://github.com/OKDP/sandbox-charts/commit/acb305be4ca1846950fb8512140ffdde926de2c0))
* **bootstrap:** OpenBao with TLS, its policies and per-namespace secrets ([155c3dc](https://github.com/OKDP/sandbox-charts/commit/155c3dcb0f6b3ec2a44e2a25ed558d2dd9ba5fbe))
* **bootstrap:** RustFS, Forgejo and the rootless CI runner ([d9ad66e](https://github.com/OKDP/sandbox-charts/commit/d9ad66e3a12c94b23dfce3b4502a77565ca4d0de))
* **cert-manager:** catalog/cert-manager/1.21.2-1.0.0, the Bundle CRD installed with trust-manager ([d97a463](https://github.com/OKDP/sandbox-charts/commit/d97a4638297992a8e7d1bc3cbd5f335eccd99a61))
* **cnpg-postgresql:** catalog/cnpg-postgresql/18.3.0-1.0.0, a package of OKDP objects only ([94adf00](https://github.com/OKDP/sandbox-charts/commit/94adf00279969ab26486da357399461d3d0f1c40))
* **cnpg-postgresql:** provider of database-server claims, the image by digest ([38342af](https://github.com/OKDP/sandbox-charts/commit/38342af5ec42f409a2f14065316651492f775543))
* **contracts:** claims in the s3 and database-server contracts ([4945f9f](https://github.com/OKDP/sandbox-charts/commit/4945f9fb084aa744272cadf9428277932f99dc5b))
* **coredns-patch:** catalog/coredns-patch/1.0.0-1.0.0, its RBAC among OKDP objects ([e8162a8](https://github.com/OKDP/sandbox-charts/commit/e8162a878c1d6d39ed6f45b3239a60788e7de467))
* **dns-server:** catalog/dns-server/1.47.1-1.0.0 ([10b2681](https://github.com/OKDP/sandbox-charts/commit/10b2681797c51f3b8ebc982b73d9514e573609df))
* **forgejo-runner:** catalog/forgejo-runner/13.2.0-1.0.0, the okdp-gitops runner on the host executor ([ca3eaf3](https://github.com/OKDP/sandbox-charts/commit/ca3eaf3b7650c1776fe272470c51e35b354fa0ef))
* **ingress-nginx:** catalog/ingress-nginx/4.15.1-1.0.0 ([af82dcc](https://github.com/OKDP/sandbox-charts/commit/af82dcc5b51f8bbe5730f8ee8978c5d73aa97f70))
* **keycloak:** catalog/keycloak/7.3.2-1.0.0, its database a connection of the context ([9a1d5e5](https://github.com/OKDP/sandbox-charts/commit/9a1d5e52596dc6b81ddf07929daa86fbf269d71d))
* **local-secrets-provider:** catalog/local-secrets-provider/1.0.0-1.0.0, its Secrets among OKDP objects ([b36fb72](https://github.com/OKDP/sandbox-charts/commit/b36fb727bf9611cba2b5929cd6ce5cbd6a0289ee))
* **local-secrets-provider:** credentials generated in the cluster, a Secret stays in its namespace ([891b41c](https://github.com/OKDP/sandbox-charts/commit/891b41cb873a548d6552d28e6a6aaf8f9742b597))
* **rustfs:** catalog/rustfs/1.0.0-1.0.0, its OAuth client chart added by the compiler ([d0eb896](https://github.com/OKDP/sandbox-charts/commit/d0eb89689a5c9495d2fe91f743b09590a667e882))
* **s3-minio-provisioner:** provider of bucket claims on an external S3 store through the MinIO admin API ([59ff786](https://github.com/OKDP/sandbox-charts/commit/59ff78606c7f7e8f45ff4b04bddaa98f755c3fa9))
* **seaweedfs:** catalog/seaweedfs/4.47.0-1.0.0 ([9365af8](https://github.com/OKDP/sandbox-charts/commit/9365af898c8f92aad0860b4eb5cc2e1545d9488d))
* **seaweedfs:** provider of s3 claims, the filer UI behind a sign-in proxy, images by digest ([4f8181b](https://github.com/OKDP/sandbox-charts/commit/4f8181bd521b8b0f6fb7dc682a5fac3e5130b216))
* the platform prerequisites removed from the catalog, the repository renamed sandbox-charts ([498d519](https://github.com/OKDP/sandbox-charts/commit/498d51993fdc295b495d60012695b172903142a4))
* **tools:** catalog/tools/1.0.0-1.0.0 ([f760a6a](https://github.com/OKDP/sandbox-charts/commit/f760a6a201f2fca14cb02c97e4a4fed8e8acbda4))
* **vault:** catalog/vault/0.34.1-1.0.0 ([a052a79](https://github.com/OKDP/sandbox-charts/commit/a052a799aaa08f5d3436fed272819ed2587a6d26))


### Documentation

* okdp.info.yaml, what an instance publishes ([4448bcb](https://github.com/OKDP/sandbox-charts/commit/4448bcbbc9608bd5dcd9137685a74c33389d04ec))
* outputs referenced by name in their namespace ([c34519d](https://github.com/OKDP/sandbox-charts/commit/c34519d257fa9ada430345d0647ce562371fce7d))
* the README, docs/deploying.md and the bootstrap README, docs/components removed ([53f0749](https://github.com/OKDP/sandbox-charts/commit/53f07498004e2f81e4aabbe42ecac0b4fbb81421))
