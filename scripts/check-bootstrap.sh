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

# Checks the sandbox's bootstrap (bootstrap/, the prerequisites of the platform that
# okdp-sandbox's scripts/bootstrap.sh installs with helm):
#   1. its YAML files parse (but the templates of its charts);
#   2. each release of bootstrap/charts.yaml has its values files, a release of a
#      chart of bootstrap/ (path) its Chart.yaml, and bootstrap/README.md holds its
#      command: helm upgrade --install <release> <chart> ... --version <version>, or
#      helm upgrade --install <release> bootstrap/<path> for a chart of bootstrap/;
#   3. every chart that is not of bootstrap/ is pinned: a repository chart by the
#      sha256 of its package (sha256), an OCI chart by the digest of its manifest
#      (digest, which bootstrap/README.md's command names); with --helm, the pins are
#      checked against the registry and repository (helm pull), and
#   3b. the CEL admission policies of bootstrap/protection, evaluated without a cluster
#      against the requests of bootstrap/protection/tests (scripts/policytest: a Go
#      test on k8s.io/apiserver's admission code), allowed and refused cases for each;
#      skipped, said so, without go (the CI has it);
#   4. with --helm: helm template of each release with its values, the chart from
#      the cache (--charts DIR, laid out as
#      <repository host and path>/<chart>-<version>/<chart>) or from its repository,
#      and no image of the rendered manifests, nor of the manifests bootstrap/ applies
#      directly, without a digest (@sha256:...).
#
# Usage: check-bootstrap.sh [--helm] [--charts DIR]
# Requires bash >= 4, yq v4; helm with --helm; go for the admission policies
# (scripts/policytest, k8s.io/apiserver's admission code, in the module cache or from the proxy).

set -euo pipefail
export LC_ALL=C

TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$TOP/bootstrap"
HELM=false
CHARTS="${OKDP_CHARTS:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --helm) HELM=true; shift ;;
    --charts) CHARTS="$2"; shift 2 ;;
    -h|--help) sed -n '18,40p' "$0"; exit 0 ;;
    *) echo "check-bootstrap: unknown argument: $1" >&2; exit 2 ;;
  esac
done
command -v yq >/dev/null || { echo "check-bootstrap: yq is required" >&2; exit 2; }
if $HELM; then
  command -v helm >/dev/null || { echo "check-bootstrap: --helm needs helm" >&2; exit 2; }
fi

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
step() { echo "== $*"; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

step "YAML syntax (bootstrap/)"
while IFS= read -r f; do
  yq -e 'true' "$f" >/dev/null 2>&1 || fail "${f#"$TOP"/}: invalid YAML"
done < <(find "$BOOTSTRAP" -path '*/templates' -prune -o -type f \( -name '*.yaml' -o -name '*.yml' \) -print | sort)

step "the releases of bootstrap/charts.yaml and the commands of bootstrap/README.md"
readme="$BOOTSTRAP/README.md"
[[ -f "$readme" ]] || fail "bootstrap/README.md is missing"
# Fields separated by | (a tab is whitespace to read: empty fields would collapse).
while IFS='|' read -r name chart version path digest sha; do
  for v in $(yq -r ".releases[\"$name\"].values[]" "$BOOTSTRAP/charts.yaml"); do
    [[ -f "$BOOTSTRAP/$v" ]] || fail "bootstrap/charts.yaml: $name: no values file bootstrap/$v"
  done
  if [[ -n "$path" ]]; then
    [[ -f "$BOOTSTRAP/$path/Chart.yaml" ]] || fail "bootstrap/charts.yaml: $name: no chart bootstrap/$path"
    grep -qF "helm upgrade --install $name bootstrap/$path " "$readme" \
      || fail "bootstrap/README.md: no command helm upgrade --install $name bootstrap/$path ..."
  elif [[ -n "$digest" ]]; then
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "bootstrap/charts.yaml: $name: digest $digest is not sha256:<64 hex>"
    grep -qF "helm upgrade --install $name $chart@$digest " "$readme" \
      || fail "bootstrap/README.md: no command helm upgrade --install $name $chart@$digest ..."
  else
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || fail "bootstrap/charts.yaml: $name: no sha256 of its package (a repository chart) nor digest (an OCI chart): nothing is installed unpinned"
    if ! grep -F "helm upgrade --install $name $chart " "$readme" | grep -qF -- "--version $version"; then
      fail "bootstrap/README.md: no command helm upgrade --install $name $chart ... --version $version"
    fi
  fi
done < <(yq -r '.releases | to_entries[] | [.key, .value.chart // "", .value.version // "", .value.path // "", .value.digest // "", .value.sha256 // ""] | join("|")' "$BOOTSTRAP/charts.yaml")

step "the admission policies of bootstrap/protection against their fixtures"
if command -v go >/dev/null; then
  # -count=1: the fixtures are not files the test cache knows of.
  if (cd "$TOP/scripts/policytest" && go test -p 1 -count=1 ./... >"$TMP/policytest.log" 2>&1); then
    echo "   ok $(find "$BOOTSTRAP/protection/tests" -name '*.yaml' | wc -l) fixtures"
  else
    fail "scripts/policytest: the admission policies do not pass their fixtures"; sed 's/^/   /' "$TMP/policytest.log"
  fi
else
  echo "   SKIPPED: go is not installed (go test -p 1 ./... in scripts/policytest)"
fi

# cached REPOSITORY CHART VERSION: the chart's directory in the cache, if there.
cached() {
  local d="$CHARTS/${1#*://}"; d="${d%/}/$2-$3/$2"
  [[ -n "$CHARTS" && -f "$d/Chart.yaml" ]] && echo "$d"
}

# undigested FILE: the image references of FILE (a manifest) without a digest, one per
# line: the value of an image: or imageName: key, and any registry/repository:tag, not
# followed by @sha256:; comments left out.
undigested() {
  {
    grep -vE '^[[:space:]]*#' "$1" \
      | grep -oE "[\"' =]([a-z0-9.-]+(:[0-9]+)?/)?[a-z0-9._-]+/[a-z0-9._/-]+:[A-Za-z0-9._-]+(@sha256:[0-9a-f]+)?" \
      | grep -vE 'https?:|kubernetes\.io|k8s\.io' | sed -E "s/^[\"' =]//"
    grep -vE '^[[:space:]]*#' "$1" \
      | sed -nE "s/^[[:space:]-]*(image|imageName): *[\"']?([^ \"']+)[\"']? *$/\\2/p"
  } | grep -v '@sha256:' | sort -u || true
}

if $HELM; then
  step "the manifests bootstrap/ applies directly: images by digest"
  while IFS= read -r f; do
    bad="$(undigested "$f")"
    [[ -z "$bad" ]] || fail "${f#"$TOP"/}: image without a digest: $(tr '\n' ' ' <<<"$bad")"
  done < <(find "$BOOTSTRAP" \( -path '*/templates' -o -path '*/tests' -o -path "$BOOTSTRAP/forgejo-runner" \) -prune -o -type f -name '*.yaml' \
    ! -name 'values.yaml' ! -name 'charts.yaml' ! -name 'realm.yaml' -print | sort)
  step "the pins of bootstrap/charts.yaml against their repositories and registries"
  mkdir -p "$TMP/pin"
  while IFS='|' read -r name chart version repo digest sha; do
    if [[ -n "$sha" ]]; then
      rm -f "$TMP/pin"/*.tgz
      if helm pull "$chart" --repo "$repo" --version "$version" -d "$TMP/pin" >/dev/null 2>"$TMP/log"; then
        got="$(sha256sum "$TMP/pin"/*.tgz | cut -d' ' -f1)"
        [[ "$got" == "$sha" ]] && echo "   ok $name (sha256 $sha)" || fail "$name: the package of $chart $version has the sha256 $got, charts.yaml pins $sha"
      else
        fail "helm pull of $name"; grep -v 'failed to load plugins' "$TMP/log" | sed 's/^/   /'
      fi
    elif [[ -n "$digest" ]]; then
      if got="$(helm pull "$chart" --version "$version" -d "$TMP/pin" 2>"$TMP/log" | sed -n 's/^Digest: //p')" && [[ -n "$got" ]]; then
        [[ "$got" == "$digest" ]] && echo "   ok $name ($digest)" || fail "$name: $chart $version has the digest $got, charts.yaml pins $digest"
      else
        fail "helm pull of $name"; grep -v 'failed to load plugins' "$TMP/log" | sed 's/^/   /'
      fi
    fi
  done < <(yq -r '.releases | to_entries[] | select(.value.path == null) | [.key, .value.chart // "", .value.version // "", .value.repo // "", .value.digest // "", .value.sha256 // ""] | join("|")' "$BOOTSTRAP/charts.yaml")
  step "helm template of the releases, their images by digest"
  while IFS='|' read -r name ns chart version repo path digest; do
    args=(-n "$ns")
    for v in $(yq -r ".releases[\"$name\"].values[]" "$BOOTSTRAP/charts.yaml"); do args+=(-f "$BOOTSTRAP/$v"); done
    if [[ -n "$path" ]]; then
      source=("$BOOTSTRAP/$path")
      # The runner's chart refuses to render without the digest of the okdp-gitops image
      # (SBX-12): a stand-in for the template, then the refusal itself is checked.
      if [[ "$name" == forgejo-runner ]]; then
        if helm template "$name" "${source[@]}" "${args[@]}" >/dev/null 2>&1; then
          fail "helm template of the release $name rendered without okdpGitopsImage.digest"
        fi
        args+=(--set "okdpGitopsImage.digest=sha256:$(printf '0%.0s' $(seq 64))")
      fi
    elif [[ -n "$digest" ]]; then
      source=("$chart@$digest")
    elif [[ -n "$repo" ]]; then
      source=("$chart" --repo "$repo" --version "$version")
      if src="$(cached "$repo" "$chart" "$version")"; then source=("$src"); fi
    else
      source=("$chart" --version "$version")
      if src="$(cached "${chart%/*}" "${chart##*/}" "$version")"; then source=("$src"); fi
    fi
    if helm template "$name" "${source[@]}" "${args[@]}" >"$TMP/out" 2>"$TMP/log"; then
      bad="$(undigested "$TMP/out")"
      if [[ -n "$bad" ]]; then
        fail "the release $name renders an image without a digest: $(tr '\n' ' ' <<<"$bad")"
      else
        echo "   ok $name ($(grep -c '^kind:' "$TMP/out") objects)"
      fi
    else
      fail "helm template of the release $name"; grep -v 'failed to load plugins' "$TMP/log" | sed 's/^/   /'
    fi
  done < <(yq -r '.releases | to_entries[] | [.key, .value.namespace, .value.chart // "", .value.version // "", .value.repo // "", .value.path // "", .value.digest // ""] | join("|")' "$BOOTSTRAP/charts.yaml")
fi

if ((failures > 0)); then
  echo "check-bootstrap: $failures failure(s)" >&2
  exit 1
fi
echo "check-bootstrap: OK"
