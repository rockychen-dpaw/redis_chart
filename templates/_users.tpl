{{- define "redis.users" }}nonroot:x:{{$.Values.redis.userid | default 999 }}:{{$.Values.redis.groupid | default 999 }}:nonroot:/home/nonroot:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/bin/sh
{{- end}}
