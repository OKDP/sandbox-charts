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

# The cluster's CoreDNS answers the ingress suffix (bootstrap/README.md, after the
# ingress controller): every name under SUFFIX, the suffix itself included, is a CNAME
# to the ingress controller's Service, for every query type. Pods then reach the
# platform's ingresses by their public names (the services' OIDC calls to Keycloak),
# and no query of the suffix (AAAA included) reaches the host's resolver, which may
# not know it. Idempotent: the template block of the suffix is replaced, and CoreDNS
# restarted only when its Corefile changed.
#
# Usage: patch.sh
# Environment: SUFFIX (default okdp.sandbox, global.okdp.ingress.suffix of the
# platform values), INGRESS_SERVICE (default
# ingress-nginx-controller.ingress-nginx.svc.cluster.local, bootstrap/ingress-nginx).
# Requires kubectl, jq, awk.

set -euo pipefail

SUFFIX="${SUFFIX:-okdp.sandbox}"
INGRESS_SERVICE="${INGRESS_SERVICE:-ingress-nginx-controller.ingress-nginx.svc.cluster.local}"
escaped="${SUFFIX//./\\.}"
# Read by awk from ENVIRON: -v would interpret the backslashes.
export SUFFIX BLOCK="template IN ANY ${SUFFIX} {
    match ^(.*\\.)?${escaped}\\.\$
    answer \"{{ .Name }} 60 IN CNAME ${INGRESS_SERVICE}.\"
    fallthrough
}"

current="$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"
# Drop the template blocks of the suffix, then insert ours before kubernetes.
new="$(printf '%s\n' "$current" | awk '
  BEGIN { s = ENVIRON["SUFFIX"]; block = ENVIRON["BLOCK"] }
  $1 == "template" && $4 == s && $NF == "{" { skip = 1; next }
  skip { if ($1 == "}") skip = 0; next }
  /^[[:space:]]*kubernetes[[:space:]]/ && !done {
    match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
    n = split(block, lines, "\n")
    for (i = 1; i <= n; i++) print ind lines[i]
    done = 1
  }
  { print }')"
if [[ "$new" == "$current" ]]; then
  echo "CoreDNS already answers $SUFFIX"
  exit 0
fi
echo "Updating the CoreDNS template for $SUFFIX"
kubectl -n kube-system patch configmap coredns --type merge \
  -p "$(jq -n --arg c "$new"$'\n' '{data: {Corefile: $c}}')"
kubectl -n kube-system rollout restart deployment coredns
kubectl -n kube-system rollout status deployment coredns --timeout=300s
echo "CoreDNS patched"
