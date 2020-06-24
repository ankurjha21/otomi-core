{{- define "chart-labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/version: {{ .Chart.Version }}
helm.sh/chart: "{{ .Chart.Name }}-{{ .Chart.Version }}"
{{- end -}}

{{- define "helm-toolkit.utils.joinListWithComma" -}}
{{- $local := dict "first" true -}}
{{- range $k, $v := . -}}{{- if not $local.first -}},{{- end -}}{{- $v -}}{{- $_ := set $local "first" false -}}{{- end -}}
{{- end -}}

{{- define "helm-toolkit.utils.joinListWithPipe" -}}
{{- $local := dict "first" true -}}
{{- range $k, $v := . -}}{{- if not $local.first -}}|{{- end -}}{{- $v -}}{{- $_ := set $local "first" false -}}{{- end -}}
{{- end -}}

{{- define "flatten-name" -}}
{{- $res := regexReplaceAll "[()/]{1}" . "" -}}
{{- regexReplaceAll "[|.]{1}" $res "-" | trimAll "-" -}}
{{- end -}}

{{- define "ingress" -}}

{{- $appsDomain := printf "apps.%s" .domain }}
{{- $ := . }}
# collect unique host and service names
{{- $routes := dict }}
{{- $names := list }}
{{- range $s := .services }}
{{- $shared := $s.isShared | default false }}
{{- $domain := (index $s "domain" | default (printf "%s.%s" $s.name ($shared | ternary $.cluster.domain $.domain))) }}
{{/*- $domain := (index $s "domain" | default (printf "%s.%s" $s.name $.domain)) */}}
{{- if not $.isApps  }}
  {{- if (not (hasKey $routes $domain)) }}
    {{- $routes = (merge $routes (dict $domain (hasKey $s "paths" | ternary $s.paths list))) }}
  {{- else }}
    {{- if $s.paths }}
      {{- $paths := index $routes $domain }}
      {{- $paths = concat $paths $s.paths }}
      {{- $routes = (merge (dict $domain $paths) $routes) }}
    {{- end }}
  {{- end }}
{{- end }}
{{/*- if not (or (has $s.name $names) ($s.internal) ($shared)) */}}
{{- if not (or (has $s.name $names) ($s.internal) $s.ownHost $s.isShared) }}
  {{- $names = (append $names $s.name) }}
{{- end }}
{{- end }}
{{- $internetFacing := or (ne .provider "nginx") (and (not .cluster.hasCloudLB) (eq .provider "nginx")) }}
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  annotations:
{{- if $internetFacing }}
    # register hosts when we are an outside facing ingress:
    externaldns: "true"
{{- end }}
{{- if eq .provider "aws" }}
    kubernetes.io/ingress.class: merge
    merge.ingress.kubernetes.io/config: merged-ingress
    alb.ingress.kubernetes.io/tags: "team=team-{{ .teamId }} {{ .ingress.tags }}"
    ingress.kubernetes.io/ssl-redirect: "true"
{{- end }}
{{- if eq .provider "azure" }}
    kubernetes.io/ingress.class: azure/application-gateway
    appgw.ingress.kubernetes.io/ssl-redirect: "true"
    appgw.ingress.kubernetes.io/backend-protocol: "http"
{{- end }}
{{- if eq .provider "nginx" }}
    kubernetes.io/ingress.class: nginx
  {{- if not .hasCloudLB }}
    ingress.kubernetes.io/ssl-redirect: "true"
  {{- end }}
{{- end }}
{{- if .isApps }}
    nginx.ingress.kubernetes.io/upstream-vhost: $1.{{ .domain }}
  {{- if .hasForward }}
    nginx.ingress.kubernetes.io/rewrite-target: /$1/$2
    {{- else }}
    nginx.ingress.kubernetes.io/rewrite-target: /$2
  {{- end }}
{{- end }}
{{- if .hasAuth }}
    nginx.ingress.kubernetes.io/auth-url: "http://oauth2-proxy.istio-system.svc.cluster.local/oauth2/auth"
    nginx.ingress.kubernetes.io/auth-signin: "https://auth.{{ .cluster.domain }}/oauth2/start?rd=/oauth2/redirect/$http_host$escaped_request_uri"
{{- end }}
{{- if or .isApps .hasAuth }}
    nginx.ingress.kubernetes.io/configuration-snippet: |
  {{- if .isApps }}
      rewrite ^/$ /otomi/ permanent;
  {{- end }}
  {{- if .hasAuth }}
      # set team header
      # TODO: remove once we have groups support via oidc
      add_header Auth-Group "{{ .teamId }}";
      proxy_set_header Auth-Group "{{ .teamId }}";
  {{- end }}
{{- end }}
  labels: {{- include "chart-labels" .dot | nindent 4 }}
  name: {{ $.provider }}-team-{{ .teamId }}-{{ .name }}
  namespace: {{ if ne .provider "nginx" }}ingress{{ else }}istio-system{{ end }}
spec:
  rules:
{{- if .isApps }}
    - host: {{ $appsDomain }}
      http:
        paths:
        - backend:
            serviceName: istio-ingressgateway
            servicePort: 80
          path: /
        - backend:
            serviceName: istio-ingressgateway
            servicePort: 80
          path: /({{ range $i, $name := $names }}{{ if gt $i 0 }}|{{ end }}{{ $name }}{{ end }})/(.*)
{{- else }}
  {{- range $domain, $paths := $routes }}
    - host: {{ $domain }}
      http:
        paths:
    {{- if not (eq $.provider "nginx") }}
      {{- if eq $.provider "aws" }}
          - backend:
              - path: /*
                backend:
                  serviceName: ssl-redirect
                  servicePort: use-annotation
      {{- end }}
          - backend:
              serviceName: nginx-ingress-controller
              servicePort: 80
    {{- else }}
      {{- if gt (len $paths) 0 }}
        {{- range $path := $paths }}
          - backend:
              serviceName: istio-ingressgateway
              servicePort: 80
          {{- if eq $path "/" }}
            path: /
          {{- else }}
            path: /{{ $path }}/
          {{- end }}
        {{- end }}
      {{- else }}
          - backend:
              serviceName: istio-ingressgateway
              servicePort: 80
      {{- end }}
    {{- end }}
  {{- end }}
  {{- if not .hasAuth }}
    # we want the user info publically available for any app that has the correct auth cookie, as it goes to auth anyway
    - host: {{ $appsDomain }}
      http:
        paths:
        - backend:
            serviceName: oauth2-proxy
            servicePort: 80
          path: /oauth2/userinfo
  {{- end }}
{{- end }}
{{- if $internetFacing }}
  tls:
  {{- if .isApps }}
    - hosts:
        - {{ $appsDomain }}
      secretName: {{ $appsDomain | replace "." "-" }}
  {{- end }}
  {{- range $domain, $paths := $routes }}
  {{- $certName := ($domain | replace "." "-") }}
    - hosts:
        - {{ $domain }}
      secretName: {{ $certName }}
  {{- end }}
{{- end }}

{{- end }}
