{{- define "redis.clear_redis" }}#!/bin/bash
#clear the whold data folder including 
# 1. redis cluster nodes file,rollback to the initial nodes file if have one
# 2. persistent data
# 3. logs
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
    if [[ -f ${REDIS_DIR}/data/nodes.conf.bak ]];then
        cp ${REDIS_DIR}/data/nodes.conf.bak /tmp/nodes.conf
        rm -rf ${REDIS_DIR}/data/*
        mv /tmp/nodes.conf ${REDIS_DIR}/data/nodes.conf
    else
        rm -rf ${REDIS_DIR}/data/*
    fi

    rm -rf ${REDIS_DIR}/logs/*
  {{- else }}
    if [[ -f ${REDIS_DIR}/${PORT}/data/nodes.conf.bak ]];then
        cp ${REDIS_DIR}/${PORT}/data/nodes.conf.bak /tmp/nodes.conf
        rm -rf ${REDIS_DIR}/${PORT}/data/*
        mv /tmp/nodes.conf ${REDIS_DIR}/${PORT}/data/nodes.conf
    else
        rm -rf ${REDIS_DIR}/${PORT}/data/*
    fi

    rm -rf ${REDIS_DIR}/${PORT}/logs/*
  {{- end }}
    ((counter++))
    ((PORT++))
done

/bin/bash
exit 0
{{- end }}
