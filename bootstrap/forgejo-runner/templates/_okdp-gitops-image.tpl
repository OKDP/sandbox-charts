{{- /*
The okdp-gitops image of the jobs, repository[:tag]@sha256:...: a digest is required
(a tag is mutable, and the image receives the output repository's write token).
*/ -}}
{{- define "forgejo-runner.okdpGitopsImage" -}}
{{- $image := .Values.okdpGitopsImage -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" (toString (default "" $image.digest))) -}}
{{- fail "okdpGitopsImage.digest must be the sha256 digest of the okdp-gitops image (sha256:<64 hex>): the job image receives the output repository's write token, a mutable tag is refused (bootstrap/README.md)" -}}
{{- end -}}
{{- printf "%s%s@%s" $image.repository (ternary (printf ":%s" $image.tag) "" (not (empty $image.tag))) $image.digest -}}
{{- end -}}
