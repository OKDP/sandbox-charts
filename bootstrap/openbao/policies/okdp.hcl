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

# okdp: the policy of the role okdp, which every ServiceAccount okdp-secrets of any
# namespace may use with a token of audience openbao (External Secrets' SecretStore,
# which the compiler writes one per project, global.okdp.secrets of platform.yaml).
# Templated on the namespace of the ServiceAccount that signs in: the metadata of the
# entity alias the auth method creates per ServiceAccount, under the accessor of the
# auth method (@ACCESSOR@, init.sh's). @MOUNT@ is the KV v2 mount. KV v2: the data of
# a key is under data/, its versions and custom metadata under metadata/. External
# Secrets' PushSecret writes both: it reads metadata/ to tell its own keys (custom
# metadata managed-by: external-secrets) and writes that metadata (create, update),
# and deletes a key, every version, through metadata/ when its claim is gone (the
# compiler's deletionPolicy Delete). Nothing lists keys. No namespace reads platform/,
# which holds no key: what a namespace needs of the platform, the platform's S3 identity
# or a client's secret, is under the keys of the namespaces that read it. The namespace
# platform would get platform/* through the first two paths: it is reserved.
#   <namespace>/*      read, write: the credentials a provider of that namespace
#                      pushes, under the claims' IDs, and the keys of the project's own
#                      connections
#   +/<namespace>.*    read: the claims of that namespace, whichever namespace
#                      provides them
path "@MOUNT@/data/{{identity.entity.aliases.@ACCESSOR@.metadata.service_account_namespace}}/*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "@MOUNT@/metadata/{{identity.entity.aliases.@ACCESSOR@.metadata.service_account_namespace}}/*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "@MOUNT@/data/+/{{identity.entity.aliases.@ACCESSOR@.metadata.service_account_namespace}}.*" {
  capabilities = ["read"]
}
