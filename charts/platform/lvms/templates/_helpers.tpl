{{- define "lvms.labels" -}}
app.kubernetes.io/name: lvms
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "lvms.namespace" -}}
{{- .Values.namespace.name -}}
{{- end -}}
