{{/* Common labels for all resources in this chart. */}}
{{- define "nfd.labels" -}}
app.kubernetes.io/name: nfd
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* The target namespace for this chart's namespaced resources. */}}
{{- define "nfd.namespace" -}}
{{- .Values.namespace.name -}}
{{- end -}}
