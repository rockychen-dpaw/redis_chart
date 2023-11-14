{{- define "redis.clear_redis" }}#!/bin/bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REDIS_DIR=$( cd -- "$( dirname -- "${SCRIPT_DIR}" )" &> /dev/null && pwd )

PORT={{ $.Values.redis.port | default 6379 | int }}
SERVERS={{ $.Values.redis.servers | default 1 | int }}
{{- $servers := $.Values.redis.servers | default 1 | int }}

#check whether all servers are up
counter=1
while [[ $counter -le $SERVERS ]]
do

    {{- if eq $servers 1 }}
    rm -rf /usr/local/redis/data/*
    {{- else }}
    rm -rf /usr/local/redis/${PORT}/data/*
    {{- end }}

    ((counter++))
    ((PORT++))
done

/bin/bash
exit 0
{{- end }}
