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
            echo "Redis Server(${PORT}) : Latest redis reset time($(cat ${serverdir}/data/redis_reset)) is invalid."
            reset_time=0
        fi
        if [[ ${reset_time} -gt ${release_time} ]];then
            echo "Redis Server(${PORT}) : Requested to reset at ${RELEASE_TIME}, but it has already been reset at $(cat ${serverdir}/data/redis_reset)"
            ((counter++))
            ((PORT++))
            continue
        fi
    fi
    if [[ "${reset_redis[${counter}]}" == "ALL" ]]; then
        #redis cluster are required to be recreated if have
        if [[ -f ${serverdir}/data/nodes.conf ]];then
            #redis cluster was created, will be removed and recreated
            recreate_cluster=1
        fi

    fi

    #backup the nodes.conf if required
    if [[ "${reset_redis[${counter}]}" == "DATA" ]] || [[ "${reset_redis[${counter}]}" == "DATA_AND_LOG" ]]; then
        if [[ -f ${serverdir}/data/nodes.conf ]];then
            echo "Redis Server(${PORT}) : Backup nodes.conf to /tmp/nodes_${PORT}.conf"
            cp ${serverdir}/data/nodes.conf /tmp/nodes_${PORT}.conf
        else
            echo "Redis Server(${PORT}) : Nodes.conf is not found, redis cluster will be recreated."
        fi
        if [[ -f ${serverdir}/data/nodes.conf.bak ]];then
            echo "Redis Server(${PORT}) : Backup nodes.conf.bak to /tmp/nodes_${PORT}.conf.bak."
            cp ${serverdir}/data/nodes.conf.bak /tmp/nodes_${PORT}.conf.bak
        else
            echo "Redis Server(${PORT}) : Nodes.conf.bak is not found"
        fi
    fi
    if [[ "${reset_redis[${counter}]}" == "NODES" ]]; then
        if [[ -f ${serverdir}/data/nodes.conf.bak ]];then
            echo "Redis Server(${PORT}) : Backup the nodes.conf.bak to /tmp/nodes_${PORT}.conf.bak."
            cp ${serverdir}/data/nodes.conf.bak /tmp/nodes_${PORT}.conf.bak
        else
            echo "Redis Server(${PORT}) : Nodes.conf.bak is not found, redis cluster will be recreated."
        fi
    fi
  
    #delete the data  if required
    if [[ "${reset_redis[${counter}]}" == "DATA" ]] || [[ "${reset_redis[${counter}]}" == "DATA_AND_LOG" ]] || [[ "${reset_redis[${counter}]}" == "NODES" ]] || [[ "${reset_redis[${counter}]}" == "ALL" ]]; then
        echo "Redis Server(${PORT}) : Clean the data folder(${serverdir}/data)"
        rm -rf ${serverdir}/data/*
    fi

    #restore the nodes.conf if required
    if [[ "${reset_redis[${counter}]}" == "DATA" ]] || [[ "${reset_redis[${counter}]}" == "DATA_AND_LOG" ]]; then
        if [[ -f /tmp/nodes_${PORT}.conf ]];then
            cp /tmp/nodes_${PORT}.conf ${serverdir}/data/nodes.conf
        fi
        if [[ -f /tmp/nodes_${PORT}.conf.bak ]];then
            mv /tmp/nodes_${PORT}.conf.bak ${serverdir}/data/nodes.conf.bak
        fi
    fi

    if [[ "${reset_redis[${counter}]}" == "NODES" ]]; then
        if [[ -f /tmp/nodes_${PORT}.conf.bak ]];then
            echo "Redis Server(${PORT}) : Restore nodes.conf from nodes.conf.bak"
            cp /tmp/nodes_${PORT}.conf.bak ${serverdir}/data/nodes.conf
            mv /tmp/nodes_${PORT}.conf.bak ${serverdir}/data/nodes.conf.bak
        fi
    fi
  
    #delete logs if required
    if [[ "${reset_redis[${counter}]}" == "LOG" ]] || [[ "${reset_redis[${counter}]}" == "DATA_AND_LOG" ]] || [[ "${reset_redis[${counter}]}" == "NODES" ]] || [[ "${reset_redis[${counter}]}" == "ALL" ]]; then
        echo "Redis Server(${PORT}) : Clean the redis log(${serverdir}/logs)"
        rm -rf ${serverdir}/logs/*
    fi

    echo "Redis Server(${PORT}) : Succeed to reset the redis server"
    echo "$(date +"%Y-%m-%dT%H:%M:%S")" > ${serverdir}/data/redis_reset

    ((counter++))
    ((PORT++))
done
exit ${recreate_cluster}
{{- end }}
