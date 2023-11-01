{{- define "redis.redis_readiness" }}#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REDIS_DIR=$( cd -- "$( dirname -- "${SCRIPT_DIR}" )" &> /dev/null && pwd )

PORT={{ $.Values.redis.port | default 6379}}
SERVERS={{ $.Values.redis.servers | default 1 }}

counter=1
while [ $counter -le $SERVERS ]
do
    res=$(redis-cli -p ${PORT} ping)
    if [[ "$?" != "0" ]] || [[ "$res" != "PONG" ]]
    then
        exit 1
    fi
    ((counter++))
    ((PORT++))
done
exit 0
{{- end }}
