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

{{- define "kubexa.agentserverFullname" -}}
{{- .Values.agentserver.fullnameOverride -}}
{{- end }}

{{/*
Parses a Kubernetes resource-quantity string (the shape
nats.config.jetstream.fileStore.pvc.size/.maxSize uses -- "16Gi", "500M", or
a bare byte count) into a plain byte count, so templates/guards.yaml can
compare it against agentserver.config.nats.jetstream.maxBytes, which is
always a raw integer.

Supports only Ki/Mi/Gi/Ti (binary) and K/M/G/T (decimal) suffixes, or no
suffix at all. Ei/E and beyond are deliberately NOT supported, even though
Kubernetes' own quantity grammar allows them: at that scale (2^60+) a value
stops being exactly representable in Sprig's float64 arithmetic (exact only
up to 2^53), and this helper would rather refuse a form it can't compute
correctly than silently return a wrong number for it.

Every accepted numeric prefix (the part before the suffix, or the whole
string when there is none) is validated against `^[0-9]+(\.[0-9]+)?$` before
being trusted -- both to reject garbage ("16Ei", "abcGi") instead of letting
Sprig's `float64` silently coerce it to 0, and because fractional prefixes
("1.5Gi") are valid Kubernetes quantities that a correct implementation has
to handle rather than round away. The multiply uses `mulf` (float
multiplication), not `mul` (which truncates its arguments to int64 first,
the reason an earlier version of this helper silently rounded "1.5Gi" down
to exactly 1Gi and "0.5Ti" down to 0). `toString` up front means an unquoted
integer from `--set foo=20000000000` (Helm/Sprig types it as int64, not a
string) is coerced before `trim`/regex see it, rather than erroring with
"wrong type for value; expected string; got int64" on the bare-byte-count
form this helper's own callers are told is supported.

Any input that doesn't fit -- an unrecognized suffix, a non-numeric prefix,
anything -- `fail`s with a message naming the exact input and what forms are
actually supported, rather than computing a byte count that quietly lies.
*/}}
{{- define "kubexa.bytesFromQuantity" -}}
{{- $orig := . -}}
{{- $q := toString . | trim -}}
{{- $numeric := "^[0-9]+(\\.[0-9]+)?$" -}}
{{- $suffixes := dict "Ki" 1024.0 "Mi" 1048576.0 "Gi" 1073741824.0 "Ti" 1099511627776.0 "K" 1000.0 "M" 1000000.0 "G" 1000000000.0 "T" 1000000000000.0 -}}
{{- $matched := false -}}
{{- range $suffix, $factor := $suffixes -}}
{{- if and (not $matched) (hasSuffix $suffix $q) -}}
{{- $matched = true -}}
{{- $prefix := trimSuffix $suffix $q -}}
{{- if not (regexMatch $numeric $prefix) -}}
{{- fail (printf "kubexa.bytesFromQuantity: %q is not a supported quantity -- %q is not a plain non-negative number, so this cannot be trusted as a %q value." $orig $prefix $suffix) -}}
{{- end -}}
{{- mulf ($prefix | float64) $factor -}}
{{- end -}}
{{- end -}}
{{- if not $matched -}}
{{- if regexMatch $numeric $q -}}
{{- $q | float64 -}}
{{- else -}}
{{- fail (printf "kubexa.bytesFromQuantity: %q is not a supported quantity form. Supported: a bare non-negative byte count, or one with a Ki/Mi/Gi/Ti (binary) or K/M/G/T (decimal) suffix. Ei/E and larger are intentionally unsupported -- see the comment above this template." $orig) -}}
{{- end -}}
{{- end -}}
{{- end }}
