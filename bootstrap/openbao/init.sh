#!/usr/bin/env bash
#
# Copyright 2026 The OKDP Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#

# Initializes OpenBao, the platform's secret store (bootstrap/openbao/values.yaml), in
# the cluster of the current kubectl context, once installed with helm
# (bootstrap/README.md) and after Keycloak and RustFS; idempotent, run it again after
# an upgrade (or after adding a client to the realm). Every call is a kubectl exec of
# bao in the server's pod, over https://127.0.0.1:8200, the server's certificate
# checked against its issuer's CA (BAO_ADDR and BAO_CACERT of the pod, values.yaml):
# no port-forward, no -tls-skip-verify, nothing on a command line but the unseal
# key (in the pod).
#   1. SANDBOX ONLY: initializes the server with one unseal key share, kept in Secret
#      openbao/openbao-init (key unseal-key), and unseals it; the sidecar of the pod
#      unseals it again at every restart. A platform holds its key shares
#      elsewhere, or auto-unseals.
#   2. The token: the root token of the initialization, the first time, which
#      enables the KV v2 mount okdp and the Kubernetes auth method kubernetes (the
#      server's own ServiceAccount reviews the tokens), and writes the policy
#      okdp-bootstrap (policies/okdp-bootstrap.hcl) and the role okdp-bootstrap (the ServiceAccount
#      openbao/okdp-bootstrap of the release, audience openbao); once a token of
#      that role signs in, the root token is revoked (kept in Secret
#      openbao/openbao-init, key root-token, until then only: a run that stops
#      before, or a sandbox of an earlier init, takes it from there). Then, and at
#      every later run, a token of the role okdp-bootstrap: a token of the
#      ServiceAccount (kubectl create token, 10 minutes, audience openbao) on the
#      exec's stdin, signed in for 15 minutes, revoked at the end. Its policy is
#      what this script writes, and no more: the policy and role okdp, the auth
#      method's configuration, the keys of the mount (written, never read: their
#      names listed; the custom metadata of the DCR tokens' keys read), the keys
#      platform/<key> of an earlier init and <namespace>/s3/platform of a
#      namespace no longer in S3_CONSUMERS (deleted). No root token remains, but
#      the unseal key is root-equivalent: Secret openbao/openbao-init holds it,
#      and whoever reads that Secret mints a new root token with
#      bao operator generate-root (the unseal key, no token), and so reads and
#      writes every credential of the platform. That is also how to recover if
#      every other way in is lost: generate a root token, write what is missing,
#      revoke it; else reinstall the release to start again. A platform keeps
#      its shares elsewhere (the sandbox keeps one in a Secret).
#      With it: the policy okdp (policies/okdp.hcl, HCL files: this script only
#      orchestrates) templated on the namespace of the ServiceAccount
#      that signs in, and the role okdp, which every ServiceAccount okdp-secrets of
#      any namespace may use with a token of audience openbao (External Secrets'
#      SecretStore, the compiler writes one per project, global.okdp.secrets of
#      platform.yaml):
#        <namespace>/*      read, write: the credentials a provider of that
#                           namespace pushes, under the claims' IDs, and the
#                           keys of the project's own connections
#        +/<namespace>.*    read: the claims of that namespace, whichever
#                           namespace provides them
#      and nothing else: no namespace reads platform/, which holds no key (the
#      namespace platform is reserved: its ServiceAccount would get platform/*
#      through the first path).
#   3. The platform's credentials, each under the keys of the namespaces that use
#      it, which no other namespace reads:
#        <namespace>/s3/platform    the platform's identity of the S3 store, keys
#                                   accessKey and secretKey of Secret
#                                   rustfs/rustfs-okdp (the identity the RustFS
#                                   release generates for the platform, s3:* on
#                                   its buckets), under each namespace of
#                                   S3_CONSUMERS (s3.yaml next to this script: the
#                                   demo), the remoteKey of the connection of its
#                                   project (the demo's platform-s3); a key
#                                   platform/s3 of an earlier init, which every
#                                   namespace read, and the key of a namespace
#                                   removed from S3_CONSUMERS are deleted. The
#                                   other namespaces claim buckets of their own
#                                   (s3-minio-provisioner);
#        <S3_PROVISIONER_NAMESPACE>/s3-provisioner
#                                   the provisioning identity of the S3 store, keys
#                                   accessKey and secretKey of Secret
#                                   rustfs/rustfs-provisioner (the identity the RustFS
#                                   release generates to create the claims' buckets,
#                                   users and policies), the remoteKey of the s3
#                                   connection the instance of s3-minio-provisioner
#                                   names, in that namespace (s3-system by default);
#        <namespace>/keycloak/<client>
#                                   the secret of a client of the realm
#                                   (bootstrap/keycloak/realm.yaml), property
#                                   client_secret: the key <client> of Secret
#                                   keycloak/keycloak-client-secrets, which
#                                   keycloak-config-cli set on the client
#                                   (bootstrap/keycloak/client-secrets.sh), under
#                                   each namespace that reads it, the client's
#                                   consumers of KEYCLOAK_CLIENTS (clients.yaml next
#                                   to this script: okdp-control-plane in
#                                   okdp-system, the services' clients in demo), read
#                                   by the compiled instances there
#                                   (local-secrets-provider, remoteKey). A client
#                                   absent from it is not written; a key
#                                   platform/keycloak/<client> of an earlier init is
#                                   deleted.
#   4. When DCR_NAMESPACES is set (space-separated project namespaces, each a
#      namespace name but platform): per-namespace initial access tokens for
#      dynamic client registration (DCR), minted via the Keycloak Admin REST API
#      (kcadm.sh in the Keycloak pod, signed in as the admin of the realm master
#      with the password on the exec's stdin, never on a command line) for the
#      realm KEYCLOAK_REALM (okdp, the realm of the platform's clients) and
#      written to <namespace>/keycloak/dcr-token (property token), which an entry
#      okdp-dcr-token of the namespace's secrets instance (the service
#      local-secrets-provider of the project, remoteKey <namespace>/keycloak/dcr-token)
#      pulls into the Secret okdp-dcr-token of the namespace: a namespace without that
#      entry gets nothing, and its oidc-dcr Jobs fail (okdp-sandbox's scripts/check.sh
#      warns of one). Each token allows DCR_TOKEN_COUNT registrations (10 by default)
#      and expires after DCR_TOKEN_EXPIRATION seconds (30 days by default; never
#      with 0). A namespace that has a token is left alone while it works: a run
#      mints a new token only when the key is absent, or its token (the id of
#      which the key's custom metadata iat-id records) is gone from Keycloak,
#      used up or within a day of its end; the key keeps one version (max-versions
#      1), and the token it replaces is deleted from Keycloak, so a namespace has
#      one token, not one more per run. A key written before this (no iat-id) is
#      kept as it is: delete it (and its token, Keycloak's admin console, realm
#      okdp, Clients, Initial access token) to have it minted again.
#
# Usage: init.sh
# Environment: OPENBAO_NAMESPACE (openbao), OPENBAO_POD (openbao-0),
# OPENBAO_BOOTSTRAP_SA (okdp-bootstrap), RUSTFS_NAMESPACE
# (rustfs), RUSTFS_SECRET (rustfs-okdp), S3_CONSUMERS (s3.yaml next to this script),
# RUSTFS_PROVISIONER_SECRET (rustfs-provisioner),
# S3_PROVISIONER_NAMESPACE (s3-system), KEYCLOAK_NAMESPACE (keycloak),
# KEYCLOAK_CLIENT_SECRETS (keycloak-client-secrets), KEYCLOAK_CLIENTS (clients.yaml
# next to this script), DCR_NAMESPACES (empty: no tokens), KEYCLOAK_POD (keycloak-0),
# KEYCLOAK_REALM (okdp), DCR_TOKEN_COUNT (10), DCR_TOKEN_EXPIRATION (2592000).
# Requires kubectl, jq and yq v4.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$DIR/../lib/common.sh"
NS="${OPENBAO_NAMESPACE:-openbao}"
POD="${OPENBAO_POD:-openbao-0}"
INIT_SECRET=openbao-init
RUSTFS_NS="${RUSTFS_NAMESPACE:-rustfs}"
RUSTFS_SECRET="${RUSTFS_SECRET:-rustfs-okdp}"
S3_CONSUMERS="${S3_CONSUMERS:-$DIR/s3.yaml}"
RUSTFS_PROVISIONER_SECRET="${RUSTFS_PROVISIONER_SECRET:-rustfs-provisioner}"
S3_PROVISIONER_NS="${S3_PROVISIONER_NAMESPACE:-s3-system}"
KEYCLOAK_NS="${KEYCLOAK_NAMESPACE:-keycloak}"
KEYCLOAK_SECRET="${KEYCLOAK_CLIENT_SECRETS:-keycloak-client-secrets}"
KEYCLOAK_CLIENTS="${KEYCLOAK_CLIENTS:-$DIR/clients.yaml}"
MOUNT=okdp
AUTH=kubernetes
ROLE=okdp
POLICY=okdp
SERVICE_ACCOUNT=okdp-secrets
AUDIENCE=openbao
BOOTSTRAP_SA="${OPENBAO_BOOTSTRAP_SA:-okdp-bootstrap}"
BOOTSTRAP=okdp-bootstrap

for c in kubectl jq yq; do
  command -v "$c" >/dev/null || { echo "openbao init: $c is required" >&2; exit 2; }
done
die() { echo "openbao init: $*" >&2; exit 1; }

# bao ARGS...: bao in the server's pod, without a token (status, init, unseal).
bao() { kubectl -n "$NS" exec -i "$POD" -c openbao -- bao "$@"; }

# bao_token: a shell script on stdin, run in the server's pod with BAO_TOKEN the
# token of TOKEN, read from the first line of its stdin (never an argument).
TOKEN=""
bao_token() {
  { printf '%s\n' "$TOKEN"; cat; } | kubectl -n "$NS" exec -i "$POD" -c openbao -- \
    sh -c 'read -r BAO_TOKEN && export BAO_TOKEN && exec sh -es'
}

# bootstrap_login: a token of the role okdp-bootstrap, signed in with a token of the
# ServiceAccount BOOTSTRAP_SA (audience openbao), on the exec's stdin.
bootstrap_login() {
  kubectl -n "$NS" create token "$BOOTSTRAP_SA" --audience="$AUDIENCE" --duration=10m \
    | kubectl -n "$NS" exec -i "$POD" -c openbao -- \
      bao write -field=token "auth/$AUTH/login" role="$BOOTSTRAP" jwt=-
}

# The token of okdp-bootstrap is revoked when the script ends, whatever its end (the
# root token only once okdp-bootstrap signs in, below).
REVOKE=false
revoke() {
  if $REVOKE; then
    bao_token <<<'bao token revoke -self >/dev/null' 2>/dev/null || true
  fi
}
trap revoke EXIT

# render_policy FILE: the policy FILE (policies/, HCL) with its placeholders, the
# constants of this script and the auth method's accessor, replaced. Nothing a user
# gives reaches a policy.
render_policy() {
  sed -e "s|@MOUNT@|$MOUNT|g" -e "s|@AUTH@|$AUTH|g" -e "s|@POLICY@|$POLICY|g" \
      -e "s|@ROLE@|$ROLE|g" -e "s|@ACCESSOR@|${accessor:-}|g" "$DIR/policies/$1"
}

echo "OpenBao ($NS/$POD): the platform's secret store"
# The server answers (bao status exits 0 unsealed, 2 sealed or not initialized).
status=""
for _ in $(seq 60); do
  status="$(bao status -format=json 2>/dev/null || true)"
  jq -e 'has("initialized")' <<<"$status" >/dev/null 2>&1 && break
  sleep 3
done
jq -e 'has("initialized")' <<<"$status" >/dev/null 2>&1 || die "no answer from $NS/$POD (helm upgrade --install openbao ..., bootstrap/README.md)"

if [[ "$(jq -r '.initialized' <<<"$status")" == false ]]; then
  init="$(bao operator init -key-shares=1 -key-threshold=1 -format=json)"
  UNSEAL_KEY="$(jq -r '.unseal_keys_b64[0]' <<<"$init")"
  ROOT_TOKEN="$(jq -r '.root_token' <<<"$init")"
  [[ -n "$UNSEAL_KEY" && -n "$ROOT_TOKEN" ]] || die "bao operator init gave no key"
  # The root token until okdp-bootstrap signs in (below), then removed.
  jq -n --arg ns "$NS" --arg name "$INIT_SECRET" --arg key "$UNSEAL_KEY" --arg token "$ROOT_TOKEN" \
    '{apiVersion: "v1", kind: "Secret", metadata: {name: $name, namespace: $ns},
      type: "Opaque", stringData: {"unseal-key": $key, "root-token": $token}}' \
    | kubectl apply -f - >/dev/null
  echo "initialized: one unseal key share in Secret $NS/$INIT_SECRET (SANDBOX ONLY)"
else
  UNSEAL_KEY="$(secret_value "$NS" "$INIT_SECRET" unseal-key)" \
    || die "initialized, but Secret $NS/$INIT_SECRET is missing: delete the release and its PersistentVolumeClaim, and install it again"
  ROOT_TOKEN="$(secret_value "$NS" "$INIT_SECRET" root-token 2>/dev/null)" || ROOT_TOKEN=""
fi

status="$(bao status -format=json 2>/dev/null || true)"
if [[ "$(jq -r '.sealed' <<<"$status")" == true ]]; then
  # The key reaches bao as an argument, in the pod: read from the exec's stdin.
  printf '%s\n' "$UNSEAL_KEY" | kubectl -n "$NS" exec -i "$POD" -c openbao -- \
    sh -c 'read -r key && bao operator unseal "$key" >/dev/null'
  echo "unsealed"
fi

kubectl -n "$NS" get serviceaccount "$BOOTSTRAP_SA" >/dev/null \
  || die "no ServiceAccount $NS/$BOOTSTRAP_SA: upgrade the release openbao (bootstrap/openbao/values.yaml)"

if [[ -n "$ROOT_TOKEN" ]]; then
  # With the root token: the mount, the auth method and its configuration, the
  # policy and the role of okdp-bootstrap; then okdp-bootstrap signs in and the root
  # token is revoked.
  TOKEN="$ROOT_TOKEN"
  mounts="$(bao_token <<<'bao secrets list -format=json')"
  if [[ "$(jq --arg m "$MOUNT/" 'has($m)' <<<"$mounts")" == false ]]; then
    bao_token <<<"bao secrets enable -path=$MOUNT -version=2 kv >/dev/null"
    echo "KV v2 mount $MOUNT: enabled"
  fi
  auths="$(bao_token <<<'bao auth list -format=json')"
  if [[ "$(jq --arg a "$AUTH/" 'has($a)' <<<"$auths")" == false ]]; then
    bao_token <<<"bao auth enable -path=$AUTH kubernetes >/dev/null"
    echo "auth method $AUTH: enabled"
  fi
  # okdp-bootstrap: what the rest of this script does, no more. The keys are
  # written, never read; their names are listed (bao kv list, for looking).
  bao_token <<EOF
bao write auth/$AUTH/config kubernetes_host=https://kubernetes.default.svc:443 >/dev/null
bao policy write $BOOTSTRAP - >/dev/null <<'POLICY'
$(render_policy okdp-bootstrap.hcl)
POLICY
bao write auth/$AUTH/role/$BOOTSTRAP bound_service_account_names=$BOOTSTRAP_SA \\
  bound_service_account_namespaces=$NS audience=$AUDIENCE \\
  token_policies=$BOOTSTRAP token_ttl=15m token_max_ttl=30m >/dev/null
EOF
  echo "policy $BOOTSTRAP and role $BOOTSTRAP of auth/$AUTH: written (ServiceAccount $NS/$BOOTSTRAP_SA)"
  bootstrap="$(bootstrap_login)" && [[ -n "$bootstrap" ]] \
    || die "ServiceAccount $NS/$BOOTSTRAP_SA cannot sign in with role $BOOTSTRAP: the root token stays in Secret $NS/$INIT_SECRET, run this script again"
  # The key first, then the revocation: a record of a revoked token is harmless, but
  # a revoked token's key left behind by a failed second step would be taken for a
  # root token by the next run. (Dropped and not revoked, the token would be a root
  # token nobody holds: the revocation below is the end of it; if it fails, the unseal
  # key's generate-root and a revocation by accessor are how to end it.)
  kubectl -n "$NS" patch secret "$INIT_SECRET" --type=json \
    -p '[{"op": "remove", "path": "/data/root-token"}]' >/dev/null
  bao_token <<<'bao token revoke -self >/dev/null' \
    || die "the root token is no longer in Secret $NS/$INIT_SECRET but was not revoked: bao operator generate-root with the unseal key, revoke the old one, or reinstall the release"
  TOKEN="$bootstrap"
  REVOKE=true
  echo "root token: removed from Secret $NS/$INIT_SECRET, revoked"
else
  TOKEN="$(bootstrap_login)" && [[ -n "$TOKEN" ]] && REVOKE=true \
    || die "ServiceAccount $NS/$BOOTSTRAP_SA cannot sign in with role $BOOTSTRAP, and Secret $NS/$INIT_SECRET holds no root token: delete the release, its PersistentVolumeClaim and that Secret, install it again and run this script"
fi
echo "signed in as $NS/$BOOTSTRAP_SA (role $BOOTSTRAP, revoked at the end)"

mounts="$(bao_token <<<'bao secrets list -format=json')"
[[ "$(jq --arg m "$MOUNT/" 'has($m)' <<<"$mounts")" == true ]] \
  || die "no mount $MOUNT/: delete the release, its PersistentVolumeClaim and Secret $NS/$INIT_SECRET, install it again and run this script"
auths="$(bao_token <<<'bao auth list -format=json')"
accessor="$(jq -r --arg a "$AUTH/" '.[$a].accessor // ""' <<<"$auths")"
[[ "$accessor" == auth_* ]] || die "no accessor of the auth method $AUTH"

# The policy okdp (policies/okdp.hcl), templated on the namespace of the ServiceAccount
# that signed in, and the role: every ServiceAccount SERVICE_ACCOUNT of every
# namespace, its tokens of audience AUDIENCE only (the TokenReview checks it: a token
# of the ServiceAccount meant for another service is refused).
bao_token <<EOF
bao policy write $POLICY - >/dev/null <<'POLICY'
$(render_policy okdp.hcl)
POLICY
bao write auth/$AUTH/config kubernetes_host=https://kubernetes.default.svc:443 >/dev/null
bao write auth/$AUTH/role/$ROLE bound_service_account_names=$SERVICE_ACCOUNT \\
  bound_service_account_namespaces='*' audience=$AUDIENCE alias_name_source=serviceaccount_uid \\
  token_policies=$POLICY token_ttl=1h token_max_ttl=24h >/dev/null
EOF
echo "policy $POLICY and role $ROLE of auth/$AUTH: written (ServiceAccount $SERVICE_ACCOUNT of any namespace, audience $AUDIENCE)"

# s3_data ACCESS_KEY SECRET_KEY: the JSON of a key of the S3 store, the values on
# jq's stdin (printf is the shell's own: no command line holds them).
s3_data() { printf '%s\n%s\n' "$1" "$2" | jq -cR -n '{accessKey: input, secretKey: input}'; }

# <namespace>/s3/platform: the platform's identity of the S3 store, under the keys of
# each namespace of S3_CONSUMERS only (the policy's <namespace>/* path), never
# platform/, which no namespace reads. The values travel in the script's text, on the
# exec's stdin. A key platform/s3 of an earlier init (every namespace read it), and
# the key of a namespace S3_CONSUMERS no longer lists, are deleted, their versions
# too (a policy okdp-bootstrap of an earlier init may not allow it: reported).
[[ -f "$S3_CONSUMERS" ]] || die "S3_CONSUMERS $S3_CONSUMERS: no such file"
s3_consumers="$(yq -o=json '.namespaces // []' "$S3_CONSUMERS")" \
  || die "$S3_CONSUMERS: invalid YAML"
jq -e 'type == "array" and all(.[]; type == "string")' <<<"$s3_consumers" >/dev/null \
  || die "$S3_CONSUMERS: namespaces is a list of namespaces"
bad="$(invalid_namespaces <<<"$s3_consumers")"
[[ -z "$bad" ]] || die "$S3_CONSUMERS: a namespace name, not platform: $(tr '\n' ' ' <<<"$bad")"
access_key="$(secret_value "$RUSTFS_NS" "$RUSTFS_SECRET" accessKey)" \
  && secret_key="$(secret_value "$RUSTFS_NS" "$RUSTFS_SECRET" secretKey)" \
  || die "Secret $RUSTFS_NS/$RUSTFS_SECRET (the platform's identity of the S3 store) is missing: install RustFS first (bootstrap/README.md)"
data="$(s3_data "$access_key" "$secret_key")"
# The namespaces of the mount (its first segments), for the keys of the namespaces
# no longer listed.
listed="$(bao_token <<<"bao kv list -format=json $MOUNT/ 2>/dev/null || echo '[]'")"
jq -e 'type == "array"' <<<"$listed" >/dev/null 2>&1 || listed='[]'
# delete_key KEY [WARN]: the shell of the pod deletes KEY's metadata and versions
# when it exists; with WARN, a refusal is reported (not fatal): the policy
# okdp-bootstrap of an earlier init reads no key but platform/keycloak/*, nor did
# that init write a key <namespace>/s3/platform.
delete_key() {
  local refused=":"
  [[ -z "${2:-}" ]] || refused="echo \"WARNING: key $1: not deleted, refused to okdp-bootstrap (its policy of an earlier init): no namespace reads it, delete it as an administrator of OpenBao\" >&2"
  printf '%s\n' "if out=\"\$(bao kv metadata get -mount=$MOUNT $1 2>&1)\"; then bao kv metadata delete -mount=$MOUNT $1 >/dev/null; echo \"key $1: deleted\";" \
    "else case \"\$out\" in *'permission denied'*) $refused ;; esac; fi"
}
script="$(
  while IFS= read -r n; do
    printf '%s\n' "bao kv put -mount=$MOUNT $n/s3/platform - >/dev/null <<'DATA'" "$data" "DATA"
  done < <(jq -r '.[]' <<<"$s3_consumers")
  delete_key platform/s3 warn
  while IFS= read -r n; do
    delete_key "$n/s3/platform"
  done < <(jq -r --argjson keep "$s3_consumers" '.[] | select(endswith("/")) | rtrimstr("/")
    | select(test("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$") and . != "platform" and (. as $n | $keep | any(. == $n) | not))' <<<"$listed")
)"
bao_token <<<"$script"
echo "keys <namespace>/s3/platform: the platform's identity of the S3 store (Secret $RUSTFS_NS/$RUSTFS_SECRET), to its consumers ($S3_CONSUMERS): $(jq -r 'join(" ")' <<<"$s3_consumers")"

# <namespace>/s3-provisioner: the provisioning identity of the S3 store, under the keys
# of the provisioner's namespace only (the policy's <namespace>/* path), never
# platform/.
valid_namespace "$S3_PROVISIONER_NS" \
  || die "S3_PROVISIONER_NAMESPACE \"$S3_PROVISIONER_NS\": a namespace name, not platform"
access_key="$(secret_value "$RUSTFS_NS" "$RUSTFS_PROVISIONER_SECRET" accessKey)" \
  && secret_key="$(secret_value "$RUSTFS_NS" "$RUSTFS_PROVISIONER_SECRET" secretKey)" \
  || die "Secret $RUSTFS_NS/$RUSTFS_PROVISIONER_SECRET (the provisioning identity of the S3 store) is missing: install RustFS first (bootstrap/README.md)"
bao_token <<EOF
bao kv put -mount=$MOUNT $S3_PROVISIONER_NS/s3-provisioner - >/dev/null <<'DATA'
$(s3_data "$access_key" "$secret_key")
DATA
EOF
echo "key $S3_PROVISIONER_NS/s3-provisioner: the provisioning identity of the S3 store (Secret $RUSTFS_NS/$RUSTFS_PROVISIONER_SECRET)"

# <namespace>/keycloak/<client>: each client's secret, as the realm has it (property
# client_secret), under the keys of each namespace KEYCLOAK_CLIENTS names for it
# (the policy's <namespace>/* path: only that namespace reads it), written in one
# script on the exec's stdin. A client it does not name is not written; a client it
# names that the realm lacks is reported. A key platform/keycloak/<client> of an
# earlier init (every namespace read it) is deleted, its versions too.
[[ -f "$KEYCLOAK_CLIENTS" ]] || die "KEYCLOAK_CLIENTS $KEYCLOAK_CLIENTS: no such file"
consumers="$(yq -o=json '.clients // {}' "$KEYCLOAK_CLIENTS")" \
  || die "$KEYCLOAK_CLIENTS: invalid YAML"
jq -e 'type == "object" and all(.[]; type == "array" and all(.[]; type == "string"))' \
  <<<"$consumers" >/dev/null \
  || die "$KEYCLOAK_CLIENTS: clients is a map of a client to a list of namespaces"
bad="$(jq -c '[.[][]]' <<<"$consumers" | invalid_namespaces)"
[[ -z "$bad" ]] || die "$KEYCLOAK_CLIENTS: a namespace name, not platform: $(tr '\n' ' ' <<<"$bad")"
! jq -e 'has("dcr-token")' <<<"$consumers" >/dev/null \
  || die "$KEYCLOAK_CLIENTS: dcr-token: the key <namespace>/keycloak/dcr-token is DCR's initial access token, not a client's"
clients="$(kubectl -n "$KEYCLOAK_NS" get secret "$KEYCLOAK_SECRET" -o json)" \
  || die "Secret $KEYCLOAK_NS/$KEYCLOAK_SECRET (the secrets of the realm's clients) is missing: install Keycloak first (bootstrap/keycloak/client-secrets.sh, bootstrap/README.md)"
script="$(jq -r --arg m "$MOUNT" --argjson to "$consumers" '.data // {} | to_entries[]
  | select(.key | test("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"))
  | "if bao kv metadata get -mount=\($m) platform/keycloak/\(.key) >/dev/null 2>&1; then bao kv metadata delete -mount=\($m) platform/keycloak/\(.key) >/dev/null; echo \"key platform/keycloak/\(.key): deleted\"; fi"
    , (. as $e | ($to[$e.key] // [])[]
      | "bao kv put -mount=\($m) \(.)/keycloak/\($e.key) - >/dev/null <<'"'"'DATA'"'"'\n\({client_secret: ($e.value | @base64d)} | tojson)\nDATA")' <<<"$clients")"
[[ -n "$script" ]] || die "Secret $KEYCLOAK_NS/$KEYCLOAK_SECRET holds no client's secret"
bao_token <<<"$script"
echo "keys <namespace>/keycloak/<client>: the secrets of the realm's clients (Secret $KEYCLOAK_NS/$KEYCLOAK_SECRET), to their consumers ($KEYCLOAK_CLIENTS):" \
  "$(sed -n 's|^bao kv put -mount=[^ ]* \([^ ]*\) .*|\1|p' <<<"$script" | tr '\n' ' ')"
skipped="$(jq -r --argjson to "$consumers" '.data // {} | keys[] | select(($to[.] // []) | length == 0)' <<<"$clients" | tr '\n' ' ')"
[[ -z "$skipped" ]] || echo "not written, no consumer in $KEYCLOAK_CLIENTS: $skipped"
missing="$(jq -r --argjson to "$consumers" '(.data // {}) as $d | $to | keys[] | select($d[.] == null)' <<<"$clients" | tr '\n' ' ')"
[[ -z "$missing" ]] || echo "WARNING: clients of $KEYCLOAK_CLIENTS without a secret in Secret $KEYCLOAK_NS/$KEYCLOAK_SECRET (not in the realm?): $missing" >&2

# Per-namespace initial access tokens for dynamic client registration (DCR). When
# platform.yaml sets global.okdp.oidc.dcr.authMethod: initialAccessToken, each
# project namespace's oidc-dcr Job authenticates to the registration endpoint with a
# bearer token read from the Secret okdp-dcr-token (key token) of its namespace, pulled
# from this store by the entry okdp-dcr-token of the namespace's secrets instance
# (local-secrets-provider; <namespace>/keycloak/dcr-token, property token). Each token is minted via the Keycloak Admin REST API (POST
# /admin/realms/<realm>/client-initial-access, a count and an expiration) from inside
# the Keycloak pod (kcadm.sh), signed in as Keycloak's admin (realm master), for the
# realm of the platform's clients, KEYCLOAK_REALM (okdp: bootstrap/keycloak/realm.yaml).
# The namespaces are the non-privileged projects: the ones that actually register
# clients by DCR. Pass them with DCR_NAMESPACES (space-separated); absent or empty:
# no tokens minted (clientProvisioning: existing; anonymous DCR, which the realm
# refuses, needs none). A namespace's token is minted when its key is absent, and
# again only when the token is gone, used up or about to expire (see 4, above).
DCR_NAMESPACES="${DCR_NAMESPACES:-}"
KEYCLOAK_POD="${KEYCLOAK_POD:-keycloak-0}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-okdp}"
DCR_TOKEN_COUNT="${DCR_TOKEN_COUNT:-10}"
DCR_TOKEN_EXPIRATION="${DCR_TOKEN_EXPIRATION:-2592000}"
# A token within this many seconds of its end is replaced.
DCR_TOKEN_MARGIN=86400

if [[ -n "$DCR_NAMESPACES" ]]; then
  for ns in $DCR_NAMESPACES; do
    valid_namespace "$ns" || die "DCR_NAMESPACES: \"$ns\" is not a namespace name, or is platform"
  done
  [[ "$DCR_TOKEN_COUNT" =~ ^[0-9]+$ && "$DCR_TOKEN_EXPIRATION" =~ ^[0-9]+$ && "$DCR_TOKEN_COUNT" -gt 0 ]] \
    || die "DCR_TOKEN_COUNT (a number above 0) and DCR_TOKEN_EXPIRATION (seconds, 0 for never) are numbers"
  echo "initial access tokens for DCR: $DCR_NAMESPACES"
  keycloak_admin_password="$(secret_value "$KEYCLOAK_NS" keycloak-admin admin-password)" \
    || die "Secret $KEYCLOAK_NS/keycloak-admin is missing"
  # kcadm ARGS...: kcadm.sh ARGS in the Keycloak pod, signed in as the admin of the
  # realm master. The password goes on the exec's stdin, then to kcadm through
  # KC_CLI_PASSWORD (without a console kcadm cannot prompt for it), so it is on no
  # command line (ps, /proc) of the pod; the session file is removed at the end.
  kcadm() {
    printf '%s\n' "$keycloak_admin_password" | kubectl -n "$KEYCLOAK_NS" exec -i "$KEYCLOAK_POD" -- \
      sh -c 'IFS= read -r KC_CLI_PASSWORD; export KC_CLI_PASSWORD
        cfg=/tmp/kcadm.config; trap "rm -f $cfg" EXIT
        kc=/opt/keycloak/bin/kcadm.sh
        "$kc" config credentials --server http://localhost:8080 --realm master --user admin --config "$cfg" >/dev/null 2>&1 \
          || { echo "kcadm: signing in as the admin of the realm master failed" >&2; exit 1; }
        "$kc" "$@" --config "$cfg"' kcadm "$@"
  }
  iats="$(kcadm get clients-initial-access -r "$KEYCLOAK_REALM")" \
    || die "listing the initial access tokens of the realm $KEYCLOAK_REALM failed"
  jq -e 'type == "array"' <<<"$iats" >/dev/null 2>&1 || die "the initial access tokens of the realm $KEYCLOAK_REALM: not a list: $iats"
  for ns in $DCR_NAMESPACES; do
    key="$ns/keycloak/dcr-token"
    old_id=""
    # Present: the mount's listing (what okdp-bootstrap's policy of every init allows).
    listed="$(bao_token <<<"bao kv list -format=json $MOUNT/$ns/keycloak 2>/dev/null || echo '[]'")"
    if jq -e 'type == "array" and index("dcr-token")' <<<"$listed" >/dev/null 2>&1; then
      meta="$(bao_token <<<"bao kv metadata get -format=json -mount=$MOUNT $key 2>/dev/null || echo '{}'")"
      old_id="$(jq -r '.data.custom_metadata["iat-id"] // empty' <<<"$meta" 2>/dev/null || true)"
      if [[ -z "$old_id" ]]; then
        echo "key $key: kept, its initial access token is not recorded (written by an earlier init, or okdp-bootstrap's policy of one cannot read it): delete the key and the token in Keycloak to have it minted again"
        continue
      fi
      if jq -e --arg id "$old_id" --argjson now "$(date +%s)" --argjson margin "$DCR_TOKEN_MARGIN" \
        '.[] | select(.id == $id and .remainingCount > 0 and (.expiration == 0 or .timestamp + .expiration - $now > $margin))' \
        <<<"$iats" >/dev/null; then
        echo "key $key: kept, its initial access token $old_id is valid"
        continue
      fi
      echo "key $key: its initial access token $old_id is gone, used up or about to end: minting a new one"
    fi
    created="$(kcadm create clients-initial-access -r "$KEYCLOAK_REALM" \
      -s "count=$DCR_TOKEN_COUNT" -s "expiration=$DCR_TOKEN_EXPIRATION" -o)" \
      || die "minting an initial access token for $ns failed"
    # The response is JSON: the token and its id.
    iat="$(jq -r '.token // empty' <<<"$created" 2>/dev/null || true)"
    id="$(jq -r '.id // empty' <<<"$created" 2>/dev/null || true)"
    [[ -n "$iat" && -n "$id" ]] || die "no token or id in the response for $ns"
    # One version of the key (the token it replaces is not kept), the token's id in its
    # custom metadata; the metadata first, so that no second version is ever written.
    bao_token <<EOF
bao kv metadata put -mount=$MOUNT -max-versions=1 -custom-metadata=iat-id=$id $key >/dev/null \\
  || echo "WARNING: key $key: metadata not written, refused to okdp-bootstrap (its policy of an earlier init): the key keeps every version and the token is not recorded" >&2
bao kv put -mount=$MOUNT $key - >/dev/null <<'DATA'
$(jq -n --arg t "$iat" '{token: $t}')
DATA
EOF
    echo "key $key: initial access token $id for DCR ($DCR_TOKEN_COUNT registrations, expiring after $DCR_TOKEN_EXPIRATION seconds, 0 for never)"
    if [[ -n "$old_id" ]]; then
      kcadm delete "clients-initial-access/$old_id" -r "$KEYCLOAK_REALM" >/dev/null 2>&1 \
        && echo "initial access token $old_id: deleted from Keycloak" \
        || echo "WARNING: initial access token $old_id not deleted from Keycloak (already gone?)" >&2
    fi
  done
fi
