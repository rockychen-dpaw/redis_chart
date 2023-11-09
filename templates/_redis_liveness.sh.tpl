{{- define "redis.redis_liveness" }}#!/bin/bash

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

declare -a masternodes
declare -a redisclusters
{{- $cluster_size := 0 }}
{{- $podid := "" }}
{{- $replica_index := 0 }}
{{- $masternodes_baseindex := 0 }}
{{- $masternodes_len := 0 }}
redisclusters_len=0
#find the cluster configuration
masternodes=()
redisclusters=()
{{- $cluster_index := 0 }}
{{- range $i,$redis_cluster := $.Values.redis.redisClusters | default dict }}
    {{- if $redis_cluster.resetMasterNodes }}
redisclusters[{{ mul $cluster_index 5 }}]={{ $redis_cluster.name}}
redisclusters[{{ add (mul $cluster_index 5) 1 }}]={{ $redis_cluster.startReset | default 0 | int }}
redisclusters[{{ add (mul $cluster_index 5) 2 }}]={{ $redis_cluster.startReset | default 24 | int }}
        {{- $cluster_size = 0 }}
        {{- range $j,$redis_node := $redis_cluster.servers }}
            {{- $cluster_size = add $cluster_size 1 }}
        {{- end }}
        {{- $masternodes_len = (div $cluster_size (add ($redis_cluster.clusterReplicas | default 1 | int) 1 | int)) | int }}
        {{- range $j,$redis_node := slice $redis_cluster.servers 0 $masternodes_len }}
            {{- range $k,$v := regexSplit ":" $redis_node -1 }}
                {{- if eq $k 0 }}
                    {{- if contains "-" $v }}
                        {{- $replica_index = (index (regexSplit "-" $v -1) 1) | int }}
                        {{- $podid = print $.Release.Name (trimPrefix "redis" (index (regexSplit "-" $v -1) 0)) "-" $replica_index}}
                    {{- else }}
                        {{- $replica_index = 0 | int }}
                        {{- $podid = print $.Release.Name (trimPrefix "redis" $v) "-" $replica_index}}
                    {{- end }}
masternodes[{{ add (mul (add $masternodes_baseindex $j) 2) $k }}]={{ print $podid | quote }}
                {{- else }}
masternodes[{{ add (mul (add $masternodes_baseindex $j) 2) $k }}]={{ $v }}
                {{- end }}
            {{- end}}
        {{- end }}
redisclusters[{{ add (mul $cluster_index 5) 3 }}]={{ $masternodes_baseindex }}
redisclusters[{{ add (mul $cluster_index 5) 4 }}]={{ $masternodes_len }}
        {{- $masternodes_baseindex = (add $masternodes_baseindex $masternodes_len) | int }}
        {{- $cluster_index = add $cluster_index 1 }}
    {{- end }}
{{- end }}
redisclusters_len={{ $cluster_index }}

index=0
hour=$(date +"%-H")
PORT={{ $.Values.redis.port | default 6379}}
while [[ $index -lt $SERVERS ]]
do
    switch_master=0
    j=0
    clustername=""
    while [[ $j -lt $redisclusters_len ]]
    do
        clustername=${redisclusters[$(($j * 5))]}
        if [[ $hour -ge ${redisclusters[$(($j * 5 + 1))]} ]] && [[ $hour -lt ${redisclusters[$(($j * 5 + 2))]} ]]
        then
            k=0
            baseindex=${redisclusters[$(($j * 5 + 3))]}
            while [[ $k -lt ${redisclusters[$(($j * 5 + 4))]} ]]
            do
                if [[ "${masternodes[$(( ($k + $baseindex) * 2 ))]}" = "${HOSTNAME}" ]] && [[ $PORT -eq ${masternodes[$((($k + $baseindex) * 2 + 1))]} ]]
                then
                    switch_master=1
                    break
                fi
                ((k++))
            done
        fi
        if [[ $switch_master -eq 1 ]]
        then
            break
        fi
        ((j++))
    done

    if [[ $switch_master -eq 0 ]]
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
        #switch master if required
        echo "Switch the redis node(${HOSTNAME}:${PORT}) to master if it is not a master node of the redis cluster(${clustername})"
        if [[ "${PASSWORDS["$PORT"]}" == "" ]]
        then
            res=$(redis-cli  -p ${PORT} cluster nodes 2>&1)
        else
            res=$(echo ${PASSWORDS["$PORT"]} | redis-cli --askpass -p $PORT cluster nodes 2>&1)
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
        nodes=$(echo -e "$res" | wc -l)
        if [[ $nodes -gt 1 ]]
        then
            #cluster is ready,check whether the current node is master or not
            is_master=$(echo -e "$res" | grep "myself" | grep "master" | wc -l )
            if [[ $is_master -eq 0 ]]
            then
                #is slave, reset it to master
                if [[ "${PASSWORDS["$PORT"]}" == "" ]]
                then
                    res=$(redis-cli  -c -h ${HOSTNAME} -p ${PORT} CLUSTER FAILOVER TAKEOVER  2>&1)
                else
                    res=$(echo ${PASSWORDS["$PORT"]} | redis-cli --askpass -c -h ${HOSTNAME} -p ${PORT} CLUSTER FAILOVER TAKEOVER 2>&1)
                fi
                status=$?
                if [[ $res = *"Connection refused"* ]]
                then 
                    #redis is not avaiable
                    echo "The redis node(${HOSTNAME}:${PORT}) is offline"
                    exit 1
                fi
                echo "Double check whether the redis node(${HOSTNAME}:${PORT}) is the master node of the redis cluster(${clustername})"
                if [[ "${PASSWORDS["$PORT"]}" == "" ]]
                then
                    res=$(redis-cli  -p ${PORT} cluster nodes 2>&1)
                else
                    res=$(echo ${PASSWORDS["$PORT"]} | redis-cli --askpass -p $PORT cluster nodes 2>&1)
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
                is_master=$(echo -e "$res" | grep "myself" | grep "master" | wc -l )
                if [[ $is_master -gt 0 ]]
                then
                    echo "Succeed to switch the node(${HOSTNAME}:${PORT}) to the master node of the redis cluster(${clustername})"
                fi
            else
                echo "The redis node(${HOSTNAME}:${PORT}) is already a master node of the redis cluster(${clustername})"
            fi
        fi
    fi
    ((index++))
    ((PORT++))
done
exit 0
{{- end }}
