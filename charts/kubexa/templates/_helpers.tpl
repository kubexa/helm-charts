{{- define "kubexa.valkeyFullname" -}}
{{- .Values.valkey.serviceName -}}
{{- end }}

{{- define "kubexa.valkeyLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: valkey
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "kubexa.valkeySelectorLabels" -}}
app.kubernetes.io/name: valkey
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "kubexa.natsLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: nats
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Parses a Kubernetes resource-quantity string (the shape both
nats.config.jetstream.fileStore.pvc.size/.maxSize and *.persistence.size
across this chart's subcharts use -- "16Gi", "500M", a bare byte count) into
a plain byte count, so templates/guards.yaml can compare it against
agentserver.config.nats.jetstream.maxBytes, which is always a raw integer.
Binary (Ki/Mi/Gi/Ti) and decimal (K/M/G/T) suffixes both round-trip through
Sprig's float64, which is exact at these magnitudes (max float64 mantissa is
2^53; a Ti-scale byte count is ~2^40) -- no precision this guard would ever
notice is lost.
*/}}
{{- define "kubexa.bytesFromQuantity" -}}
{{- $q := trim . -}}
{{- if hasSuffix "Ki" $q }}{{ mul (trimSuffix "Ki" $q | float64) 1024 }}
{{- else if hasSuffix "Mi" $q }}{{ mul (trimSuffix "Mi" $q | float64) 1048576 }}
{{- else if hasSuffix "Gi" $q }}{{ mul (trimSuffix "Gi" $q | float64) 1073741824 }}
{{- else if hasSuffix "Ti" $q }}{{ mul (trimSuffix "Ti" $q | float64) 1099511627776 }}
{{- else if hasSuffix "K" $q }}{{ mul (trimSuffix "K" $q | float64) 1000 }}
{{- else if hasSuffix "M" $q }}{{ mul (trimSuffix "M" $q | float64) 1000000 }}
{{- else if hasSuffix "G" $q }}{{ mul (trimSuffix "G" $q | float64) 1000000000 }}
{{- else if hasSuffix "T" $q }}{{ mul (trimSuffix "T" $q | float64) 1000000000000 }}
{{- else }}{{ $q | float64 }}
{{- end -}}
{{- end }}
