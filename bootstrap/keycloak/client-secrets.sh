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

# The secrets of the realm's clients (realm.yaml), generated in the cluster of the
# current kubectl context before the Keycloak release is installed
# (bootstrap/README.md): Secret keycloak/keycloak-client-secrets, one key per client
# whose secret the realm reads, "$(file:UTF-8:/secrets/clients/<client>)"
# (keycloak-config-cli's variable substitution: its Job, values.yaml, mounts the
# Secret at /secrets/clients), each value 32 random bytes in hexadecimal (64
# characters). Created once: a key the Secret holds is kept, a missing one added (run
# it again after adding a client to the realm). The values travel on kubectl's
# standard input, never on a command line, never in Git. bootstrap/openbao/init.sh
# then copies each into the platform's secret store, the key
# <namespace>/keycloak/<client> (property client_secret) of each namespace that
# reads it (bootstrap/openbao/clients.yaml), where the compiled instances of that
# namespace read it (local-secrets-provider, remoteKey): Keycloak and the cluster
# hold the same secret, which nothing writes by hand.
#
# Usage: client-secrets.sh
# Environment: KEYCLOAK_NAMESPACE (keycloak), KEYCLOAK_CLIENT_SECRETS
# (keycloak-client-secrets). Requires kubectl.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${KEYCLOAK_NAMESPACE:-keycloak}"
SECRET="${KEYCLOAK_CLIENT_SECRETS:-keycloak-client-secrets}"
MOUNT=/secrets/clients

# shellcheck source=../lib/common.sh
source "$DIR/../lib/common.sh"
command -v kubectl >/dev/null || { echo "keycloak client secrets: kubectl is required" >&2; exit 2; }
die() { echo "keycloak client secrets: $*" >&2; exit 1; }

# The clients whose secret the realm reads from the Secret.
clients="$(grep -o "\$(file:UTF-8:$MOUNT/[a-z0-9-]*)" "$DIR/realm.yaml" | sed "s|.*$MOUNT/||; s|)\$||" | sort -u)"
[[ -n "$clients" ]] || die "$DIR/realm.yaml reads no client secret from $MOUNT"

# The keys of the Secret, when it exists.
exists=false keys=""
if kubectl -n "$NS" get secret "$SECRET" >/dev/null 2>&1; then
  exists=true
  keys="$(kubectl -n "$NS" get secret "$SECRET" -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}')"
fi

# A random value for each client the Secret lacks (hexadecimal: plain JSON text).
data="" added=""
for client in $clients; do
  if grep -qx -- "$client" <<<"$keys"; then continue; fi
  data+="${data:+,}\"$client\":\"$(random_hex 32)\""
  added+=" $client"
done

if [[ -z "$added" ]]; then
  echo "Secret $NS/$SECRET: every client's secret is there, kept ($(wc -w <<<"$clients") clients)"
elif $exists; then
  printf '{"stringData":{%s}}' "$data" | kubectl -n "$NS" patch secret "$SECRET" --type merge --patch-file /dev/stdin >/dev/null
  echo "Secret $NS/$SECRET: generated the secrets of$added"
else
  printf '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"%s","namespace":"%s"},"type":"Opaque","stringData":{%s}}' \
    "$SECRET" "$NS" "$data" | kubectl create -f - >/dev/null
  echo "Secret $NS/$SECRET: generated the secrets of$added"
fi
