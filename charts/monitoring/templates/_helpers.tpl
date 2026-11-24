{{- define "monitoring.fullname" -}}
{{ .Release.Name }}
{{- end }}
{{- define "monitoring.labels" -}}
app.kubernetes.io/name: monitoring
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
