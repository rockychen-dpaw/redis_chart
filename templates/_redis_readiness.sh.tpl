{{- define "redis.redis_readiness" }}#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REDIS_DIR=$( cd -- "$( dirname -- "${SCRIPT_DIR}" )" &> /dev/null && pwd )

{{- $redis_conf := (get $.Values.redis "redis.conf") | default dict  }}
PORT={{ $.Values.redis.port | default 6379}}
SERVERS={{ $.Values.redis.servers | default 1 }}

declare -A PASSWORDS
{{- $start_port := $.Values.redis.port | default 6379 |int }}
{{- $servers := $.Values.redis.servers | default 1 | int }}
{{- $end_port := add $start_port $servers | int  }}
{{- $redis_conf := (get $.Values.redis "redis.conf") | default dict  }}
{{- $redisport_conf := dict }}
{{- range $i,$port := untilStep $start_port $end_port 1 }}
    {{- $redisport_conf = (get $.Values.redis (print "redis_" $port ".conf")) | default dict }}
PASSWORDS[{{ $port | quote }}]={{ (get $redisport_conf "requirepass") | default (get $redis_conf "requirepass") | default "" | quote }}
{{- end }}

counter=1
while [ $counter -le $SERVERS ]
do
    if [[ "${PASSWORDS["$PORT"]}" == "" ]]
    then
        res=$(redis-cli -p $PORT ping 2>&1)
    else
        res=$(echo ${PASSWORDS["$PORT"]} | redis-cli --askpass -p $PORT ping 2>&1)
    fi
    status=$?
    if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]] || [[ "$res" != "PONG" ]]
    then
        exit 1
    fi
    ((counter++))
    ((PORT++))
done
exit 0
{{- end }}
