{{- define "redis.redis_readiness" }}#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REDIS_DIR=$( cd -- "$( dirname -- "${SCRIPT_DIR}" )" &> /dev/null && pwd )
WORKLOAD_NAME={{ $.Release.Name }}

{{- $redis_conf := (get $.Values.redis "redis.conf") | default dict  }}
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

declare -a clusternodes
declare -a redisclusters
{{- $cluster_size := 0 }}
{{- $podid := "" }}
{{- $replica_index := 0 }}
{{- $clusternodes_baseindex := 0 }}
redisclusters_len=0
#find the cluster configuration
clusternodes=()
redisclusters=()
{{- $cluster_index := 0 }}
{{- range $i,$redis_cluster := $.Values.redis.redisClusters | default dict }}
redisclusters[{{ mul $cluster_index 3 }}]={{ $redis_cluster.name}}
    {{- $cluster_size = 0 }}
    {{- range $j,$redis_node := $redis_cluster.servers }}
        {{- $cluster_size = add $cluster_size 1 }}
    {{- end }}
    {{- range $j,$redis_node := $redis_cluster.servers }}
        {{- range $k,$v := regexSplit ":" $redis_node -1 }}
            {{- if eq $k 0 }}
                {{- if contains "-" $v }}
                    {{- $replica_index = (index (regexSplit "-" $v -1) 1) | int }}
                    {{- $podid = print $.Release.Name (trimPrefix "redis" (index (regexSplit "-" $v -1) 0)) "-" $replica_index}}
                {{- else }}
                    {{- $replica_index = 0 | int }}
                    {{- $podid = print $.Release.Name (trimPrefix "redis" $v) "-" $replica_index}}
                {{- end }}
clusternodes[{{ add (mul (add $clusternodes_baseindex $j) 2) $k }}]={{ print $podid | quote }}
            {{- else }}
clusternodes[{{ add (mul (add $clusternodes_baseindex $j) 2) $k }}]={{ $v }}
            {{- end }}
        {{- end}}
    {{- end }}
redisclusters[{{ add (mul $cluster_index 3) 1 }}]={{ $clusternodes_baseindex }}
redisclusters[{{ add (mul $cluster_index 3) 2 }}]={{ $cluster_size }}
    {{- $clusternodes_baseindex = (add $clusternodes_baseindex $cluster_size) | int }}
    {{- $cluster_index = add $cluster_index 1 }}
{{- end }}
redisclusters_len={{ $cluster_index }}

index=0
min_ready_seconds=0
PORT={{ $.Values.redis.port | default 6379}}
while [[ $index -lt $SERVERS ]]
do
    is_cluster=0
    j=0
    clustername=""
    while [[ $j -lt $redisclusters_len ]]
    do
        clustername=${redisclusters[$(($j * 3))]}
        k=0
        baseindex=${redisclusters[$(($j * 3 + 1))]}
        while [[ $k -lt ${redisclusters[$(($j * 3 + 2))]} ]]
        do
            if [[ "${clusternodes[$(( ($k + $baseindex) * 2 ))]}" = "${HOSTNAME}" ]] && [[ $PORT -eq ${clusternodes[$((($k + $baseindex) * 2 + 1))]} ]]
            then
                is_cluster=1
                break
            fi
            ((k++))
        done
        if [[ $is_cluster -eq 1 ]]
        then
            break
        fi
        ((j++))
    done

    if [[ $is_cluster -eq 0 ]]
    then
        #no need to switch master
        echo "Check whether the redis node(${HOSTNAME}:${PORT}) is online"
        if [[ "${PASSWORDS["$PORT"]}" == "" ]]
        then
            res=$(redis-cli -p $PORT ping 2>&1)
        else
            res=$(echo ${PASSWORDS["$PORT"]} | redis-cli --askpass -p $PORT ping 2>&1)
        fi
        status=$?
        if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]] || [[ "$res" != "PONG" ]]
        then
            echo "The redis node(${HOSTNAME}:${PORT}) is offline"
            exit 1
        fi
    else
        #is cluster node
        if [[ "${PASSWORDS["$PORT"]}" == "" ]]
        then
            res=$(redis-cli  -p ${PORT} cluster info 2>&1)
        else
            res=$(echo ${PASSWORDS["$PORT"]} | redis-cli --askpass -p $PORT cluster info 2>&1)
        fi
        status=$?
        if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]]
        then 
            #redis is not avaiable
            echo "The redis node(${HOSTNAME}:${PORT}) is offline"
            exit 1
        fi
        if [[ $res ==  *ERR* ]]
        then
            #doesn't support cluster feature
            echo "The redis node(${HOSTNAME}:${PORT}) does not support cluster feature"
            exit 1
        fi
        res=$(echo "$res" | grep "cluster_state")
        if [[ $res = *cluster_state:ok* ]]
        then
            min_ready_seconds={{ $.Values.redis.minReadySeconds | default 15 }}
        fi
    fi
    ((index++))
    ((PORT++))
done
if [[ $min_ready_seconds -gt 0 ]]
then
    echo "Some of the redis servers running in this node(${HOSTNAME}) are belonging to redis clusters.Wait ${min_ready_seconds} seconds before changing to status 'ready'"
    sleep ${min_ready_seconds}
fi
exit 0
{{- end }}
