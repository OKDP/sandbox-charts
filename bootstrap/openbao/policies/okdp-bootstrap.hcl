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

# okdp-bootstrap: what init.sh does, no more (the role okdp-bootstrap, the
# ServiceAccount openbao/okdp-bootstrap). The keys are written, never read, but the
# metadata of the DCR tokens' keys; their names are listed (bao kv list).
# @MOUNT@, @AUTH@, @POLICY@ and @ROLE@ are the constants of init.sh (the KV mount, the
# Kubernetes auth method, the policy and the role of the namespaces).
path "sys/mounts" {
  capabilities = ["read"]
}
path "sys/auth" {
  capabilities = ["read"]
}
path "sys/policies/acl/@POLICY@" {
  capabilities = ["create", "update"]
}
path "auth/@AUTH@/config" {
  capabilities = ["create", "update"]
}
path "auth/@AUTH@/role/@ROLE@" {
  capabilities = ["create", "update"]
}
path "@MOUNT@/data/*" {
  capabilities = ["create", "update"]
}
path "@MOUNT@/metadata/*" {
  capabilities = ["list"]
}
# The keys of an earlier init, deleted: platform/..., and <namespace>/s3/platform of a
# namespace that is no longer a consumer.
path "@MOUNT@/metadata/platform/*" {
  capabilities = ["read", "delete"]
}
path "@MOUNT@/metadata/+/s3/platform" {
  capabilities = ["read", "delete"]
}
# The DCR tokens: one version of the key, the token's id in its custom metadata.
path "@MOUNT@/metadata/+/keycloak/dcr-token" {
  capabilities = ["create", "read", "update"]
}
