{{- define "lws.labels" -}}
app.kubernetes.io/name: lws
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "lws.namespace" -}}
{{- .Values.namespace.name -}}
{{- end -}}
