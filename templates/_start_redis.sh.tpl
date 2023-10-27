{{- define "redis.start_redis" }}#!/bin/bash


SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REDIS_DIR=$( cd -- "$( dirname -- "${SCRIPT_DIR}" )" &> /dev/null && pwd )

PORT={{ .Values.redis.port | default 6379}}
SERVERS={{ .Values.redis.servers | default 1 }}

counter=1
while [ $counter -le $SERVERS ]
do
    redis-server $REDIS_DIR/conf/redis_$PORT.conf 
    if [[ "$?" != "0" ]]
    then
        echo "Failed to started the ${counter}th redis server on port ${PORT}"
        exit 1
    fi
    echo "Started the ${counter}th redis server on port ${PORT}"
    ((counter++))
    ((PORT++))

done

/bin/bash
{{- end }}
