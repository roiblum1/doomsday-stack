{{- define "network.labels" -}}
app.kubernetes.io/name: network
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "network.namespace" -}}
{{- .Values.namespace.name -}}
{{- end -}}

{{/*
  Render the RDMA shared device plugin JSON config. Context must be a dict with:
    - resourceName
    - rdmaHcaMax
    - selectors (dict of vendor/deviceID/linkType selectors)
    - ifNames (list, optional)
*/}}
{{- define "network.rdmaConfig" -}}
{{- $cfg := dict "resourceName" .resourceName "rdmaHcaMax" .rdmaHcaMax "selectors" .selectors }}
{{- if .ifNames }}
{{- $_ := set $cfg.selectors "ifNames" .ifNames }}
{{- end }}
{{- dict "configList" (list $cfg) | mustToJson }}
{{- end -}}
