{{/*
Chart name, overridable so two releases can coexist in one namespace.
*/}}
{{- define "sample-nodejs.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified name. Truncated to 63 characters because that is the limit for a label
value, and these names are used as label values below.
*/}}
{{- define "sample-nodejs.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "sample-nodejs.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Labels applied to every object. Includes app.kubernetes.io/version so `kubectl get` shows
which application version is deployed without inspecting the pod spec.
*/}}
{{- define "sample-nodejs.labels" -}}
helm.sh/chart: {{ include "sample-nodejs.chart" . }}
{{ include "sample-nodejs.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: sample-nodejs
{{- end }}

{{/*
Selector labels only. Kept separate and deliberately minimal: a Deployment's selector is
immutable, so anything volatile in here (chart version, app version) would make every
chart upgrade a delete-and-recreate.
*/}}
{{- define "sample-nodejs.selectorLabels" -}}
app.kubernetes.io/name: {{ include "sample-nodejs.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "sample-nodejs.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "sample-nodejs.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Resolve the image reference, preferring a digest over a tag.

A tag is a mutable pointer: ghcr.io/x/y:1.2.3 can be repushed with different content, so
what Trivy scanned is not provably what runs. The release pipeline therefore writes the
digest. The tag remains supported for local development where digests are inconvenient.
*/}}
{{- define "sample-nodejs.image" -}}
{{- if .Values.image.digest }}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else if .Values.image.tag }}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag }}
{{- else }}
{{- printf "%s:%s" .Values.image.repository (.Chart.AppVersion | default "latest") }}
{{- end }}
{{- end }}
