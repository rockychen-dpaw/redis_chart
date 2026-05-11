{{- define "redis.groups" }}nonroot:x:{{$.Values.redis.groupid | default 999 }}:nonroot
shadow:x:42:
nobody:x:65534:
{{- end}}
