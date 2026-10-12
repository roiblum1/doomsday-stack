{{/* Fullname: release-qualified prefix for all names. */}}
{{- define "qwen36-judge.fullname" -}}
{{- if .Values.nameOverride -}}
{{- .Values.nameOverride -}}
{{- else -}}
{{- .Release.Name -}}
{{- end -}}
{{- end -}}

{{/* Common labels. */}}
{{- define "qwen36-judge.labels" -}}
app.kubernetes.io/name: {{ include "qwen36-judge.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* Model URI (s3:// preferred; the storage-initializer downloads to
     /mnt/models). Kept as a helper so the llmisvc template stays
     render-logic-free. */}}
{{- define "qwen36-judge.modelUri" -}}
{{- .Values.model.uri -}}
{{- end -}}
