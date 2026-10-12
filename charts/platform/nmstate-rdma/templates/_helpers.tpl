{{- define "nmstate-rdma.labels" -}}
app.kubernetes.io/name: nmstate-rdma
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "nmstate-rdma.namespace" -}}
{{- .Values.namespace.name -}}
{{- end -}}
