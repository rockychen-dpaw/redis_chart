{{- define "redis.reset_redis" }}#!/bin/bash
#clear the whold data folder including 
# 1. redis cluster nodes file,rollback to the initial nodes file if have one
# 2. persistent data
# 3. logs

#Return 
#0: clean succeed, no nodes.conf are removed
#1: clean succeed, some clusters are required to be recreated

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REDIS_DIR=$( cd -- "$( dirname -- "${SCRIPT_DIR}" )" &> /dev/null && pwd )

source ${SCRIPT_DIR}/functions

PORT={{ $.Values.redis.port | default 6379 | int }}
SERVERS={{ $.Values.redis.servers | default 1 | int }}
{{- $servers := $.Values.redis.servers | default 1 | int }}

declare -a reset_redis
{{- $reset_config := $.Values.redis.reset | default "DISABLED" }}
{{- $port := $.Values.redis.port | default 6379 | int }}
{{- $reset_required := false }}
{{- range $i,$j := until $servers }}
    {{- if kindIs "string" $reset_config }}
reset_redis[{{$i}}]={{ upper $reset_config }}
    {{- else }}
reset_redis[{{$i}}]={{ upper (get $reset_config ($port | toString) | default "DISABLED") }}
    {{- end }}
    {{- $port = add $port 1 }}
{{- end }}

recreate_cluster=0
#check whether all servers are up
echo "Begin to reset redis servers if requested"
counter=0
release_time=$(date --date ${RELEASE_TIME} +"%s")
clean=0
while [[ $counter -lt $SERVERS ]]
do
    if [[ "${reset_redis[${counter}]}" != "LOG" ]] && [[ "${reset_redis[${counter}]}" != "DATA_AND_LOG" ]] && [[ "${reset_redis[${counter}]}" != "NODES" ]] && [[ "${reset_redis[${counter}]}" != "ALL" ]] && [[ "${reset_redis[${counter}]}" != "DATA" ]]; then
        echo "Redis Server(${PORT}) : No need to reset the redis server"
        ((counter++))
        ((PORT++))
        continue
    fi
  {{- if eq $servers 1 }}
    serverdir="${REDIS_DIR}"
  {{- else }}
    serverdir="${REDIS_DIR}/${PORT}"
  {{- end }}
    #check whether reset action has been done before
    if [[ -f ${serverdir}/data/redis_reset ]];then
        reset_time=$(date -f ${serverdir}/data/redis_reset +"%s")
        if [[ $? -ne 0 ]];then
            log "${serverdir}" "Redis Server(${PORT}) : Latest redis reset time($(cat ${serverdir}/data/redis_reset)) is invalid."
            reset_time=0
        fi
        if [[ ${reset_time} -gt ${release_time} ]];then
            log "${serverdir}" "Redis Server(${PORT}) : Requested to reset at ${RELEASE_TIME}, but it has already been reset at $(cat ${serverdir}/data/redis_reset)"
            ((counter++))
            ((PORT++))
            continue
        fi
    fi
    #delete the data  if required
    if [[ "${reset_redis[${counter}]}" == "DATA" ]] || [[ "${reset_redis[${counter}]}" == "DATA_AND_LOG" ]] || [[ "${reset_redis[${counter}]}" == "NODES" ]] || [[ "${reset_redis[${counter}]}" == "ALL" ]]; then
        log  "${serverdir}" "Redis Server(${PORT}) : Clean all persistent data"
        rm -rf ${serverdir}/data/appendonlydir/*
        rm -rf ${serverdir}/data/dump.rdb
    fi

    #restore the nodes.conf if required
    if [[ "${reset_redis[${counter}]}" == "NODES" ]]; then
        if [[ -f ${serverdir}/data/nodes.conf.bak ]];then
            log "${serverdir}" "Redis Server(${PORT}) : Restore the nodes.conf from ${serverdir}/data/nodes.conf.bak"
            cp -f ${serverdir}/data/nodes.conf.bak ${serverdir}/data/nodes.conf
        else
            log "${serverdir}" "Redis Server(${PORT}) : The file(${serverdir}/data/nodes.conf.bak) doesn't exist, recreate the redis cluster if needed"
        fi
        recreate_cluster=1
    elif [[ "${reset_redis[${counter}]}" == "ALL" ]]; then
        #redis cluster are required to be recreated if have
        log "${serverdir}" "Redis Server(${PORT}) : Remove the files nodes.conf and nodes.conf.bak to recreate the redis cluster"
        recreate_cluster=1
        rm -rf ${serverdir}/data/nodes.conf
        rm -f ${serverdir}/data/nodes.conf.bak
    fi

    #delete logs if required
    if [[ "${reset_redis[${counter}]}" == "LOG" ]] || [[ "${reset_redis[${counter}]}" == "DATA_AND_LOG" ]] || [[ "${reset_redis[${counter}]}" == "NODES" ]] || [[ "${reset_redis[${counter}]}" == "ALL" ]]; then
        log "${serverdir}" "Redis Server(${PORT}) : Clean all redis logs(${serverdir}/logs)"
        rm -rf ${serverdir}/logs/*
    fi

    echo "Redis Server(${PORT}) : Succeed to reset the redis server"
    echo "$(date +"%Y-%m-%dT%H:%M:%S")" > ${serverdir}/data/redis_reset

    ((counter++))
    ((PORT++))
done
exit ${recreate_cluster}
{{- end }}
