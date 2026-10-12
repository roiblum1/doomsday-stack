{{- define "nrop.labels" -}}
app.kubernetes.io/name: numaresources
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "nrop.namespace" -}}
{{- .Values.namespace.name -}}
{{- end -}}
