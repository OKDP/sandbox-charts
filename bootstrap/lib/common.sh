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

# The helpers the bootstrap's scripts share (openbao/init.sh, keycloak/client-secrets.sh),
# sourced: random_hex, secret_value, and the namespace names the platform accepts
# (valid_namespace, invalid_namespaces: one definition for the S3 consumers, the
# clients' consumers and the DCR namespaces of openbao/init.sh).

# random_hex BYTES: BYTES random bytes, in hexadecimal.
random_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# secret_value NAMESPACE SECRET KEY: the value of KEY of a Secret of the current
# context; fails when the Secret or the key is missing.
secret_value() {
  local v
  v="$(kubectl -n "$1" get secret "$2" -o "jsonpath={.data.$3}")" && [[ -n "$v" ]] || return 1
  printf '%s' "$v" | base64 -d
}

# A namespace name: a DNS label of 63 characters at most, not platform (the namespace
# platform is reserved: the keys platform/... of the secret store are the platform's,
# and the policy of a namespace gives it <namespace>/*).
NAMESPACE_RE='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'

# valid_namespace NAME: whether NAME is a namespace name the platform accepts.
valid_namespace() { [[ "$1" =~ $NAMESPACE_RE && ${#1} -le 63 && "$1" != platform ]]; }

# invalid_namespaces: reads a JSON array of strings on stdin, prints each that is no
# namespace name the platform accepts, JSON-quoted, one per line.
invalid_namespaces() {
  jq -r --arg re "$NAMESPACE_RE" '.[] | select((test($re) and length <= 63 and . != "platform") | not) | "\"\(.)\""'
}
