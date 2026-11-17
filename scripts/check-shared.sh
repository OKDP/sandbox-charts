#!/usr/bin/env bash
#
# Copyright 2026 The OKDP Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Checks that the files the OKDP catalog repositories share are
# byte-identical in this repository and in each one given, checked out
# beside it:
#
#   scripts/check-shared.sh <catalog dir>...
#   scripts/check-shared.sh ../community-charts ../sandbox-charts
#
# The shared files: scripts/check-shared.sh, LICENSE, the workflows
# release-please.yml and conventional-commits.yml of .github/workflows/, and
# each contract both repositories hold (contracts/<contract>.schema.json of
# one name). OKDP/platform-charts holds the canonical copies: a change of a
# shared file is made there and copied to every catalog in the same pass,
# which CI cannot check (no catalog reads another).
#
# Exits 1 when a shared file differs or is missing, printing its diff.
set -euo pipefail

[[ $# -gt 0 ]] || { echo "usage: $0 <catalog dir>..." >&2; exit 2; }
repo=$(cd "$(dirname "$0")/.." && pwd -P)
shared=(
  scripts/check-shared.sh
  LICENSE
  .github/workflows/release-please.yml
  .github/workflows/conventional-commits.yml
)

# compare <file> <other repository>: the file of both repositories.
# Prints the diff; fails when they differ.
compare() {
  diff -u "${repo}/$1" "$2/$1"
}

rc=0
for other in "$@"; do
  other=$(cd "${other}" && pwd -P)
  files=("${shared[@]}")
  for f in "${repo}"/contracts/*.schema.json; do
    [[ ! -f "${other}/contracts/${f##*/}" ]] || files+=("contracts/${f##*/}")
  done
  differ=0
  for f in "${files[@]}"; do
    if [[ ! -f "${repo}/${f}" || ! -f "${other}/${f}" ]]; then
      echo "FAIL ${f}: missing in ${repo} or ${other}"
      differ=1
    elif ! out=$(compare "${f}" "${other}"); then
      echo "FAIL ${f}: differs in ${other}"
      printf '%s\n' "${out}"
      differ=1
    fi
  done
  if [[ ${differ} -eq 0 ]]; then
    echo "ok   ${other}: ${#files[@]} shared files identical"
  else
    rc=1
  fi
done
exit "${rc}"
