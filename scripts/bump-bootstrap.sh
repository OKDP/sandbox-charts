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

# Prints what bootstrap/ pins, as the registries and repositories serve it now, to move
# the pins together with a version (it edits nothing; network reads only):
#   charts   each release of bootstrap/charts.yaml that is not of bootstrap/: the
#            sha256 of its package (repository chart) or the digest of its manifest
#            (OCI chart) at its version, with the one charts.yaml pins;
#   images   each image the releases render (helm template of the pinned chart with its
#            values) as repository:tag@sha256:...: the digest the tag has now, with
#            the one the values pin; an image rendered without a digest is printed
#            with the one to add. An image rendered by digest alone (cert-manager's,
#            trust-manager's, Reloader's: the chart's appVersion is the tag) has no tag
#            to look up: look up the tag of the chart's appVersion and compare.
# A line "differs" is a tag that moved upstream or a pin to update with its version;
# paste the new value in charts.yaml and the values file, then run
# scripts/check-bootstrap.sh --helm.
#
# Usage: bump-bootstrap.sh
# Requires bash >= 4, yq v4, helm, and crane or skopeo.

set -euo pipefail
export LC_ALL=C

TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$TOP/bootstrap"
for c in yq helm; do
  command -v "$c" >/dev/null || { echo "bump-bootstrap: $c is required" >&2; exit 2; }
done
if command -v crane >/dev/null; then
  tag_digest() { crane digest "$1"; }
elif command -v skopeo >/dev/null; then
  tag_digest() { skopeo inspect --format '{{.Digest}}' "docker://$1"; }
else
  echo "bump-bootstrap: crane or skopeo is required" >&2; exit 2
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
differs=0

echo "== charts (bootstrap/charts.yaml)"
while IFS='|' read -r name chart version repo digest sha; do
  if [[ -n "$repo" ]]; then
    rm -rf "${TMP:?}/pin"; mkdir -p "$TMP/pin"
    if helm pull "$chart" --repo "$repo" --version "$version" -d "$TMP/pin" >/dev/null 2>&1; then
      now="$(sha256sum "$TMP/pin"/*.tgz | cut -d' ' -f1)"
      if [[ "$now" == "$sha" ]]; then echo "$name $version: sha256 $now"; else echo "$name $version: sha256 $now (charts.yaml: ${sha:-none}) differs"; differs=1; fi
    else
      echo "$name $version: helm pull of $chart from $repo failed" >&2; differs=1
    fi
  else
    rm -rf "${TMP:?}/pin"; mkdir -p "$TMP/pin"
    now="$(helm pull "$chart" --version "$version" -d "$TMP/pin" 2>/dev/null | sed -n 's/^Digest: //p')" || now=""
    if [[ -z "$now" ]]; then echo "$name $version: helm pull of $chart failed" >&2; differs=1
    elif [[ "$now" == "$digest" ]]; then echo "$name $version: digest $now"
    else echo "$name $version: digest $now (charts.yaml: ${digest:-none}) differs"; differs=1; fi
  fi
done < <(yq -r '.releases | to_entries[] | select(.value.path == null) | [.key, .value.chart // "", .value.version // "", .value.repo // "", .value.digest // "", .value.sha256 // ""] | join("|")' "$BOOTSTRAP/charts.yaml")

echo "== images (rendered by the releases)"
: >"$TMP/images"
while IFS='|' read -r name ns chart version repo path digest; do
  args=(-n "$ns")
  for v in $(yq -r ".releases[\"$name\"].values[]" "$BOOTSTRAP/charts.yaml"); do args+=(-f "$BOOTSTRAP/$v"); done
  if [[ -n "$path" ]]; then
    source=("$BOOTSTRAP/$path")
    [[ "$name" != forgejo-runner ]] || args+=(--set "okdpGitopsImage.digest=sha256:$(printf '0%.0s' $(seq 64))")
  elif [[ -n "$digest" ]]; then source=("$chart@$digest")
  else source=("$chart" --repo "$repo" --version "$version"); fi
  helm template "$name" "${source[@]}" "${args[@]}" 2>/dev/null \
    | grep -vE '^[[:space:]]*#' \
    | grep -oE "[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+(:[A-Za-z0-9._-]+)?(@sha256:[0-9a-f]{64})?" \
    | grep -E '^(docker\.io|quay\.io|ghcr\.io|registry\.k8s\.io|code\.forgejo\.org|[a-z0-9-]+/[a-z0-9._-]+(:|@))' \
    | grep -vE '^(https?|app\.kubernetes|kubernetes|k8s)\.' >>"$TMP/images" || true
done < <(yq -r '.releases | to_entries[] | [.key, .value.namespace, .value.chart // "", .value.version // "", .value.repo // "", .value.path // "", .value.digest // ""] | join("|")' "$BOOTSTRAP/charts.yaml")
# The Cluster of Keycloak's database, applied directly.
grep -hoE 'imageName: *[^ ]+' "$BOOTSTRAP/keycloak/database.yaml" | sed 's/^imageName: *//' >>"$TMP/images"

sort -u "$TMP/images" | while IFS= read -r ref; do
  repo="${ref%%@*}"
  pinned=""; [[ "$ref" != *@* ]] || pinned="${ref#*@}"
  # a tag after the last / (else a port, or none)
  if [[ "${repo##*/}" != *:* ]]; then
    [[ -z "$pinned" ]] || echo "$repo@$pinned: no tag to look up (chart appVersion)"
    continue
  fi
  if now="$(tag_digest "$repo" 2>/dev/null)" && [[ -n "$now" ]]; then
    if [[ -z "$pinned" ]]; then echo "$repo: add @$now (rendered without a digest)"
    elif [[ "$now" == "$pinned" ]]; then echo "$repo: $now"
    else echo "$repo: $now (pinned: $pinned) differs"; fi
  else
    echo "$repo: no digest (registry unreachable or private)" >&2
  fi
done | tee "$TMP/report"
grep -q 'differs\|add @' "$TMP/report" && differs=1

((differs == 0)) || { echo "bump-bootstrap: some pins differ or are missing (above)" >&2; exit 1; }
echo "bump-bootstrap: every pin is what the registries serve now"
