{{- define "redis.start_redis" }}#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REDIS_DIR=$( cd -- "$( dirname -- "${SCRIPT_DIR}" )" &> /dev/null && pwd )

PORT={{ $.Values.redis.port | default 6379 | int }}
SERVERS={{ $.Values.redis.servers | default 1 | int }}
NODENAME="$1"

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

#check whether all servers are up
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
        if [[ $SERVERS -eq 1 ]]
        then
            echo "redis-server $REDIS_DIR/conf/redis.conf"
            redis-server $REDIS_DIR/conf/redis.conf
        else
            echo "redis-server $REDIS_DIR/${PORT}/conf/redis.conf"
            redis-server $REDIS_DIR/${PORT}/conf/redis.conf
        fi
        if [[ $? -eq 0 ]]
        then
            echo "Succeed to start the ${counter}th redis server on port ${PORT}"
        else
            echo "Failed to start the ${counter}th redis server on port ${PORT}"
            exit 1
        fi
        #double check whether it is runnint
        attempts=0
        while [[ true ]]
        do
            if [[ "${PASSWORDS["$PORT"]}" == "" ]]
            then
                res=$(redis-cli -p $PORT ping 2>&1)
            else
                res=$(echo ${PASSWORDS["$PORT"]} | redis-cli --askpass -p $PORT ping 2>&1)
            fi
            status=$?
            if [[ $status -eq 0 ]] && [[ $res != *"Connection refused"* ]] && [[ "${res}" = "PONG" ]]
            then
                echo "The redis server(127.0.0.1:${PORT}) is ready to use."
                break
            elif [[ ${attempts} -gt 300 ]]
            then
                echo "The redis server(127.0.0.1:${PORT}) is down."
                exit 1
            fi
            sleep 1
            ((attempts++))
        done
    else
        echo "The ${counter}th redis server on port ${PORT} has already been started"
    fi
    ((counter++))
    ((PORT++))
done

function check_related_clusters(){
    #check whether the related clusters are created.
    local server=""
    local port=0
    local index=0
    local PORT=0
    index=0
    while [[ $index -lt $cluster_size ]]
    do
        server=${cluster_nodes[$(( $index * 2 ))]}
        port=${cluster_nodes[$(( $index * 2 + 1 ))]}
        if [[ "${server}" == "${NODENAME}" ]]
        then
            echo "The redis server(${NODENAME}:${port}) is the member of the redis cluster(${cluster_name}). Check whether it was created or not."
            attempts=0
            while [[ true ]]
            do
                if [[ "${PASSWORDS["$port"]}" == "" ]]
                then
                    res=$(redis-cli  -p ${port} cluster info 2>&1)
                else
                    res=$(echo ${PASSWORDS["$port"]} | redis-cli --askpass -p $port cluster info 2>&1)
                fi
                status=$?
                if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]]
                then
                    echo "The redis server(127.0.0.1:${port}) is not running,status=${status}"
                    return -1
                fi
                if [[ $res ==  *ERR* ]]
                then
                    echo "The redis server(127.0.0.1:${port}) does not support cluster feature"
                    return -1
                fi
                res=$(echo "$res" | grep "cluster_state")
                if [[ $res = *cluster_state:ok* ]]
                then
                    echo "The redis cluster(${cluster_name}) has alreay been created."
                    return 0
                fi
                if [[ $SERVERS -eq 1 ]]
                then
                    nodes_file="${REDIS_DIR}/data/nodes.conf"
                else
                    nodes_file="${REDIS_DIR}/${port}/data/nodes.conf"
                fi
                if ! [[ -f "${nodes_file}" ]]
                then
                    echo "Can't find the nodes.conf.the redis server(127.0.0.1:${port}) does not support cluster feature"
                    return -1
                fi
                lines=$(cat ${nodes_file} | grep -E "(slave)|(master)" | wc -l)
                if [[ ${lines} -gt 1 ]]
                then
                    if [[ $attempts -gt 300 ]]
                    then
                        echo "The nodes file(${nodes_file}) contains ${lines} nodes, but cluster status is failed."
                        return -2
                    else
                        echo "The nodes file(${nodes_file}) contains ${lines} nodes, the redis cluster should be created.wait 1 second and check again."
                        sleep 1
                        ((attempts++))
                        continue
                    fi
                fi
                
                if [[ $index -eq 0 ]]
                then
                    echo "The redis cluster(${cluster_name}) is not created. create it now.stauts=${res}"
                    return 1
                else
                    echo "The redis cluster(${cluster_name}) is not created. let the node(${cluster_nodes[0]}) create it"
                    return 0
                fi
            done
            break
        fi
        ((index++))
    done
    echo "The redis server(${NODENAME}) is not belonging to the redis cluster(${cluster_name})."
    return 0
}

function precheck(){
    echo "Check whether all redis nodes are running"
    local index=0
    local server=""
    local port=0
    while [[ $index -lt $cluster_size ]]
    do
        server=${cluster_nodes[$(( $index * 2 ))]}
        port=${cluster_nodes[$(( $index * 2 + 1 ))]}
        echo "Check whether the redis server(${server}:${port}) is running"
        while [[ true ]]
        do
            if [[ "${PASSWORDS["$port"]}" == "" ]]
            then
                res=$(redis-cli -h ${server} -p ${port} cluster info 2>&1)
            else
                res=$(echo ${PASSWORDS["$port"]} | redis-cli --askpass -h ${server} -p $port cluster info 2>&1)
            fi
            status=$?
            if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]]
            then
                echo "The redis server(${cluster_nodes[0]}:${cluster_nodes[1]}) is not running,waiting"
                sleep 1
                continue
            fi
            if [[ $res == *ERR* ]]
            then
                echo "The redis server(${server}:${port}) does not support cluster feature"
                return -1
            fi
            res=$(echo "$res" | grep "cluster_state")
            if [[ $res = *cluster_state:ok* ]]
            then
                echo "The redis server(${server}:${port}) is already belonging to a redis cluster"
                return -1
            fi
            echo "The redis server(${server}:${port}) is running and ready to join to a redis cluster."
            break
        done
        ((index++))
    done
    echo "All related redis servers are up and ready to join the redis cluster(${cluster_name})"
    return 0
}

declare -a cluster_nodes
{{- $cluster_size := 0 }}
{{- $cluster_nodes_str := "" }}
{{- $nodeip := "" }}
#check the clusters one by one, create it if required
#find the cluster configuration
{{- range $i,$redis_cluster := $.Values.redis.redisClusters | default dict }}
    {{- $cluster_size = 0 }}
    {{- $cluster_nodes_str = "" }}
cluster_nodes=()
cluster_name={{ $redis_cluster.name }}
    {{- range $j,$redis_node := $redis_cluster.servers }}
        {{- if gt $j 0 }}
            {{- $cluster_nodes_str = print $cluster_nodes_str " "}}
        {{- end}}
        {{- $cluster_size = add $cluster_size 1 }}
        {{- range $k,$v := regexSplit ":" $redis_node -1 }}
            {{- if eq $k 0 }}
                {{- $nodeip = get (index $.Values.redis.workloads (sub (trimPrefix "redis" $v | int) 1)) "clusterip" }}
                
cluster_nodes[{{ add (mul $j 2) $k }}]={{ (print $nodeip) | quote }}
                {{- $cluster_nodes_str = print $cluster_nodes_str $nodeip }}
            {{- else }}
cluster_nodes[{{ add (mul $j 2) $k }}]={{ $v }}
                {{- $cluster_nodes_str = print $cluster_nodes_str ":" $v }}
            {{- end }}
        {{- end}}
    {{- end }}
cluster_size={{ $cluster_size }}
cluster_nodes_str={{ $cluster_nodes_str | quote }}

check_related_clusters
status=$?
if [[ $status -lt 0 ]]
then
    exit 1
fi
if [[ $status -eq 1 ]]
then
    precheck
    staus=$?
    if [[ $status -lt 0 ]]
    then
        exit 1
    fi
    if [[ $status -eq 0 ]]
    then
        echo "Try to create the cluster for the redis server(${cluster_nodes[0]}:${cluster_nodes[1]})"
        if [[ "${PASSWORDS["${cluster_nodes[1]}"]}" == "" ]]
        then
            redis-cli --cluster create ${cluster_nodes_str} --cluster-replicas {{ get $redis_cluster "clusterReplicas" | default 1 }} --cluster-yes 
        else
            echo ${PASSWORDS["${cluster_nodes[1]}"]} | redis-cli --askpass --cluster create ${cluster_nodes_str} --cluster-replicas {{ get $redis_cluster "clusterReplicas" | default 1 }} --cluster-yes
        fi
        status=$?
        if [[ $status -ne 0 ]]
        then
            echo "Failed to create the redis cluster(${cluster_name})"
            exit 1
        fi
        echo "Succeed to create the redis cluster(${cluster_name})"

        echo "Double check whether the cluster(${cluster_name}) has been created"
        attempts=0
        while [[ true ]]
        do
            if [[ "${PASSWORDS["${cluster_nodes[1]}"]}" == "" ]]
            then
                res=$(redis-cli -c -h ${cluster_nodes[0]} -p ${cluster_nodes[1]} cluster info 2>&1)
            else
                res=$(echo ${PASSWORDS["${cluster_nodes[1]}"]} | redis-cli -c --askpass -h ${cluster_nodes[0]} -p ${cluster_nodes[1]} cluster info)
            fi
            status=$?
            if [[ $status -ne 0 ]]
            then
                echo "The redis server(${cluster_nodes[0]}:${cluster_nodes[1]}) is not running"
                exit 1
            fi
            res=$(echo "$res" | grep "cluster_state")
            if [[ $res = *cluster_state:ok* ]]
            then
                echo "The redis cluster(${cluster_name}) is ready"
                break
            elif [[ $attempts -gt 300 ]]
            then
                echo "Failed to create the redis cluster(${cluster_name})"
                exit 1
            fi
            sleep 1
            ((attempts++))
        done
    fi
fi
{{- end }}

/bin/bash
exit 0
{{- end }}
