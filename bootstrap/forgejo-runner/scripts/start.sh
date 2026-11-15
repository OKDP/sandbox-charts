#!/bin/bash
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

# The runner's entry point: its configuration (config.yml of the ConfigMap) with a
# connection per repository it is registered for, a key of the registration Secret
# each (the --secret of forgejo forgejo-cli actions register: 40 hexadecimal
# characters, the runner's UUID its first 16 as hexadecimal bytes), then the daemon.
# Usage: start.sh FORGEJO_URL
# Environment: REGISTRATION_SECRET, the Secret's name (for the messages).

set -euo pipefail

url="$1"
config=/data/config.yml
cp /etc/forgejo-runner/conf/config.yml "${config}"
printf 'server:\n  connections:\n' >>"${config}"
n=0
for token in /etc/forgejo-runner/registration/*; do
  [[ -f ${token} ]] || continue
  name=${token##*/}
  secret=$(<"${token}")
  secret=${secret//[[:space:]]/}
  if [[ ! ${secret} =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "forgejo-runner: key ${name} of Secret ${REGISTRATION_SECRET} must be 40 hexadecimal characters (the --secret of forgejo forgejo-cli actions register)" >&2
    exit 1
  fi
  hex=
  for ((i = 0; i < 16; i++)); do
    printf -v hex '%s%02x' "${hex}" "'${secret:i:1}"
  done
  uuid=${hex:0:8}-${hex:8:4}-${hex:12:4}-${hex:16:4}-${hex:20:12}
  printf '    "%s":\n      url: "%s"\n      uuid: "%s"\n      token_url: "file:%s"\n' \
    "${name}" "${url}" "${uuid}" "${token}" >>"${config}"
  n=$((n + 1))
done
if ((n == 0)); then
  echo "forgejo-runner: Secret ${REGISTRATION_SECRET} holds no registration secret" >&2
  exit 1
fi
exec forgejo-runner daemon --config "${config}"
