{{- define "redis.start_redis" }}#!/bin/bash


SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REDIS_DIR=$( cd -- "$( dirname -- "${SCRIPT_DIR}" )" &> /dev/null && pwd )

PORT={{ $.Values.redis.port | default 6379 | int }}
SERVERS={{ $.Values.redis.servers | default 1 | int }}
NODENAME="$1"

counter=1
while [ $counter -le $SERVERS ]
do
    res=$(redis-cli -p $PORT ping)
    if [[ $? -ne 0 ]] || [[ "$res" != "PONG" ]]
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
            echo "Started the ${counter}th redis server on port ${PORT}"
        else
            echo "Failed to started the ${counter}th redis server on port ${PORT}"
            exit 1
        fi
    else
        echo "The ${counter}th redis server on port ${PORT} has already been started"
    fi
    ((counter++))
    ((PORT++))
done

#get all redis clusters
echo "Try to create redis cluster whose first node is ${NODENAME}"
declare -a servers
{{- $size := 0 }}
{{- $nodes := "" }}
{{- $nodeip := "" }}
{{- range $i,$redis_cluster := get $.Values.redis "redis-clusters" }}
    {{- $size = 0 }}
    {{- $nodes = "" }}
servers=()
    {{- range $j,$redis_node := $redis_cluster.servers }}
        {{- if gt $j 0 }}
            {{- $nodes = print $nodes " "}}
        {{- end}}
        {{- $size = add $size 1 }}
        {{- range $k,$v := regexSplit ":" $redis_node -1 }}
            {{- if eq $k 0 }}
                {{- $nodeip = get (index $.Values.redis.workloads (sub (trimPrefix "workload" $v | int) 1)) "clusterip" }}
                
servers[{{ add (mul $j 2) $k }}]={{ (print $nodeip) | quote }}
                {{- $nodes = print $nodes $nodeip }}
            {{- else }}
servers[{{ add (mul $j 2) $k }}]={{ $v }}
                {{- $nodes = print $nodes ":" $v }}
            {{- end }}
        {{- end}}
    {{- end }}
size={{ $size }}
nodes={{ $nodes | quote }}
if [[ "${servers[0]}" = "$NODENAME" ]]
then
    echo "Check whether all redis nodes are running"
    index=0
    while [[ $index -lt $size ]]
    do
        server=${servers[$(( $index * 2 ))]}
        port=${servers[$(( $index * 2 + 1 ))]}
        echo "Check whether the redis server(${server}:${port}) is running"
        while true
        do
            res=$(redis-cli -c -h ${server} -p ${port} cluster info)
            if [[ $? -ne 0 ]]
            then
                echo "The redis server(${servers[0]}:${servers[1]}) is not running,waiting"
                sleep 1
                continue
            fi
            if [[ $res ==  ERR* ]]
            then
                echo "The redis server(${server}:${port}) does not support cluster feature"
                exit 1
            fi
            res=$(echo "$res" | grep "cluster_state")
            if [[ $res = *cluster_state:ok* ]]
            then
                if [[ $index -eq 0 ]]
                then
                    echo "The redis cluster has alreay been created."
                    /bin/bash
                    exit 0
                else
                    echo "The redis server(${server}:${port}) has already joined into a redis cluster."
                    exit 1
                fi
            fi
            echo "The redis server(${server}:${port}) is running and ready to join to a redis cluster."
            break
        done
        ((index++))
    done


    echo "Try to create the cluster for the redis server(${servers[0]}:${servers[1]})"
    redis-cli --cluster create ${nodes} --cluster-replicas {{ get $redis_cluster "cluster-replicas" | default 1 }} --cluster-yes
    if [[ $? -ne 0 ]]
    then
        echo "Failed to create the cluster for the redis server(${servers[0]}:${servers[1]})"
        exit 1
    fi
    echo "Succeed to create the cluster for the redis server(${servers[0]}:${servers[1]})"
    
    echo "Double check whether the clustera has been created for the redis server(${servers[0]}:${servers[1]})"
    res=$(redis-cli -c -h ${servers[0]} -p ${servers[1]} cluster info)
    if [[ $? -ne 0 ]]
    then
        echo "The redis server(${servers[0]}:${servers[1]}) is not running"
        exit 1
    fi
    res=$(echo "$res" | grep "cluster_state")
    if [[ $res = *cluster_state:ok* ]]
    then
        echo "The cluster has been created for the redis server(${servers[0]}:${servers[1]})"
    else
        echo "Failed to create the cluster for the redis server(${servers[0]}:${servers[1]})"
        exit 1
    fi
fi
{{- end }}

/bin/bash
exit 0
{{- end }}
