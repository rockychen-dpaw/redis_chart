{{- define "redis.start_redis" }}#!/bin/bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REDIS_DIR=$( cd -- "$( dirname -- "${SCRIPT_DIR}" )" &> /dev/null && pwd )

PORT={{ $.Values.redis.port | default 6379 | int }}
SERVERS={{ $.Values.redis.servers | default 1 | int }}

{{- $cluster_size := 0 }}
{{- $cluster_groups := 0 }}
{{- $master_nodes_str := "" }}
{{- $podid := "" }}
{{- $nodeip := "" }}
{{- $workload_index := 0 }}
{{- $replicas := $.Values.redis.replicas | default 1 | int }}
{{- $redis_conf := (get $.Values.redis "redis.conf") | default dict }}
{{- $redisport_conf := false }}
{{- $save := false }}
{{- $appendonly := false }}
{{- $persistent := 0 }}
{{- $replica_index := 0 }}
#check the clusters one by one, create it if required
#find the cluster configuration
{{- range $i,$redis_cluster := $.Values.redis.redisClusters | default dict }}
declare -a {{ $redis_cluster.name}}_nodes
    {{- $cluster_size = 0 }}
    {{- range $j,$redis_node := $redis_cluster.servers }}
        {{- $cluster_size = add $cluster_size 1 }}
    {{- end }}
    {{- $master_nodes_str = "" }}
{{ $redis_cluster.name}}_nodes=()
{{ $redis_cluster.name}}_name={{ $redis_cluster.name }}
    {{- $cluster_groups = div $cluster_size (add ($redis_cluster.clusterReplicas | default 1) 1) | int }}
    {{- range $j,$redis_node := $redis_cluster.servers }}
        {{- if and (gt $j 0) (lt $j $cluster_groups) }}
            {{- $master_nodes_str = print $master_nodes_str " "}}
        {{- end}}
        {{- range $k,$v := regexSplit ":" $redis_node -1 }}
            {{- if eq $k 0 }}
                {{- if contains "-" $v }}
                    {{- $replica_index = (index (regexSplit "-" $v -1) 1) | int }}
                    {{- $workload_index =  sub ((trimPrefix "redis" (index (regexSplit "-" $v -1) 0)) | int ) 1 }}
                    {{- $podid = print $.Release.Name (trimPrefix "redis" (index (regexSplit "-" $v -1) 0)) "-" $replica_index}}
                {{- else }}
                    {{- $replica_index = 0 | int }}
                    {{- $workload_index =  sub ((trimPrefix "redis" $v) | int ) 1 }}
                    {{- $podid = print $.Release.Name (trimPrefix "redis" $v) "-" $replica_index}}
                {{- end }}
                {{- if and (eq $replicas 1) (get (index $.Values.redis.workloads $workload_index) "clusterip") }}
                    {{ $nodeip = get (index $.Values.redis.workloads $workload_index) "clusterip" }}
                {{- else }}
                    {{ $nodeip = index (get (index $.Values.redis.workloads $workload_index) "clusterips") $replica_index }}
                {{- end }}

{{ $redis_cluster.name}}_nodes[{{ mul $j 3 }}]={{ print $podid | quote }}
{{ $redis_cluster.name}}_nodes[{{ add (mul $j 3) 1 }}]={{ print $nodeip | quote }}
                {{- if lt $j $cluster_groups }}
                    {{- $master_nodes_str = print $master_nodes_str $nodeip }}  
                {{- end }}
            {{- else }}
                {{- $redisport_conf = (get $.Values.redis (print "redis_" $v ".conf")) | default dict }}
                {{- $save = get $redisport_conf "save" | default (get $redis_conf "save") | default "\"\"" }}
                {{- $appendonly = get $redisport_conf "appendonly" | default (get $redis_conf "appendonly") | default "no" }}
{{ $redis_cluster.name}}_nodes[{{ add (mul $j 3) 2 }}]={{ $v }}
                {{- if not $save }}
                    {{- $save = "\"\"" }}
                {{- end }}
                {{- if or (ne $save "\"\"")  (ne $appendonly  "no") }}
                    {{- $persistent = 1 }}
                {{- else }}
                    {{- $persistent = 0 }}
                {{- end }}
                {{- if lt $j $cluster_groups }}
                    {{- $master_nodes_str = print $master_nodes_str ":" $v }}
                {{- end }}
            {{- end }}
        {{- end}}
    {{- end }}
{{ $redis_cluster.name}}_size={{ $cluster_size }}
{{ $redis_cluster.name}}_slaves={{ $redis_cluster.clusterReplicas | default 1 }}
{{ $redis_cluster.name}}_groups={{ div $cluster_size (add ($redis_cluster.clusterReplicas | default 1) 1) | int }}
{{ $redis_cluster.name}}_persistent={{ $persistent }}
{{- if ($redis_cluster.resetMasterNodes | default false) }}
{{ $redis_cluster.name}}_reset_masternodes=1
{{- else }}
{{ $redis_cluster.name}}_reset_masternodes=0
{{- end }}
{{ $redis_cluster.name}}_nodes_str={{ $master_nodes_str | quote }}

{{- end }}

declare -A PASSWORDS
{{- $replicas := $.Values.redis.replicas | default 1 | int }}
{{- $workload_index := 0 }}
{{- $replica_index := 0 }}
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
while [[ $counter -le $SERVERS ]]
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
      #redis server is not started
      #switch the redis master if this server is belong to a redis cluster which is persistent disabled, and also the corresponding redis server has not taken over yet.
      switch_required=0
      {{- range $i,$redis_cluster := $.Values.redis.redisClusters | default dict }}
      cluster_name={{ print "${" $redis_cluster.name "_name}" }}
      cluster_nodes={{ print "( \"${" $redis_cluster.name "_nodes[@]}\" )" }}  
      cluster_size={{ print "${" $redis_cluster.name "_size}" }}
      cluster_slaves={{ print "${" $redis_cluster.name "_slaves}" }}
      cluster_groups={{ print "${" $redis_cluster.name "_groups}" }}
      cluster_persistent={{ print "${" $redis_cluster.name "_persistent}" }}

      if [[ ${cluster_persistent} -eq 0 ]]
      then
          #cluster doesn't support persistent. so master switch is required 
          index=0
          while [[ $index -lt ${cluster_size} ]]
          do
              server=${cluster_nodes[$(( $index * 3 ))]}
              port=${cluster_nodes[$(( $index * 3 + 2 ))]}
              if [[ "${server}" == "${HOSTNAME}" ]] && [[ ${port} -eq ${PORT} ]]
              then
                  echo "The redis server(127.0.0.1:${PORT}) is offline and belonging to the redis cluster(${cluster_name}), check whether the related slave server should be switched to master node"
                  #this redis server is blonging to this cluster
                  j=1
                  new_master_index=-1
                  while [[ $j -le ${cluster_slaves} ]]
                  do
                      other_index=$((($index + $j * $cluster_groups) % ${cluster_size}))
                      other_server=${cluster_nodes[$(( $other_index * 3 + 1 ))]}
                      other_port=${cluster_nodes[$(( $other_index * 3 + 2 ))]}
                      echo "Check whether the server(${other_server}:${other_port}) is master."
                      if [[ "${PASSWORDS["${other_port}"]}" == "" ]]
                      then
                          res=$(redis-cli -h ${other_server} -c -p ${other_port} cluster nodes 2>&1)
                      else
                          res=$(echo ${PASSWORDS["${other_port}"]} | redis-cli --askpass -c -h ${other_server} -p ${other_port} cluster nodes 2>&1)
                      fi
                      status=$?
                      if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]] || [[ $res = *ERR* ]]
                      then 
                          echo "The server(${other_server}:${other_port}) is offline."
                      else
                          nodes=$(echo -e "$res" | wc -l )
                          if [[ $nodes -lt 2 ]]
                          then
                              echo "The server(${other_server}:${other_port}) does not join the redis cluster(${cluster_name}) ."
                          else
                              is_master=$(echo -e "$res" | grep "myself" | grep "master" | wc -l )
                              if [[ ${is_master} -eq 1 ]]
                              then
                                  echo "The server(${other_server}:${other_port}) is master, no need to switch."
                                  new_master_index=-1
                                  break
                              else
                                  new_master_index=${other_index}
                              fi
                          fi
                      fi
                      ((j++))
                  done
                  if [[ ${new_master_index} -ge 0 ]]
                  then
                      #switch the master server
                      new_master_server=${cluster_nodes[$(( $new_master_index * 3 + 1 ))]}
                      new_master_port=${cluster_nodes[$(( $new_master_index * 3 + 2 ))]}
                      echo "Try to switch the server(${new_master_server}:${new_master_port}) to master."
                      if [[ "${PASSWORDS["${new_master_port}"]}" == "" ]]
                      then
                          res=$(redis-cli -h ${new_master_server} -p ${new_master_port} cluster failover takeover 2>&1)
                      else
                          res=$(echo ${PASSWORDS["${new_master_port}"]} | redis-cli --askpass -h ${new_master_server} -p ${new_master_port} cluster failover takeover 2>&1)
                      fi
                      status=$?
                      if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]] || [[ $res = *ERR* ]]
                      then 
                          echo "Failed to switch the server(${new_master_server}:${new_master_port}) to master node."
                          exit 1
                      fi
                      echo "Succeed to switch the server(${new_master_server}:${new_master_port}) to master node."
                  fi
                  break
              fi
              ((index++))
          done
      else
          echo "The redis cluster($cluster_name) supports persistent, no need to switch the slave node to master node manually"
      fi
      {{- end}}

      {{- if eq $replicas 1 }}
        if [[ $SERVERS -eq 1 ]]
        then
            echo "Start the redis server: redis-server $REDIS_DIR/conf/redis.conf"
            redis-server $REDIS_DIR/conf/redis.conf
        else
            echo "Start the redis server: redis-server $REDIS_DIR/${PORT}/conf/redis.conf"
            redis-server $REDIS_DIR/${PORT}/conf/redis.conf
        fi
      {{- else }}
        if [[ $SERVERS -eq 1 ]]
        then
            echo "Start the redis server: rredis-server $REDIS_DIR/conf/${HOSTNAME}/redis.conf"
            redis-server $REDIS_DIR/conf/${HOSTNAME}/redis.conf
        else
            echo "Start the redis server: redis-server $REDIS_DIR/${PORT}/conf/${HOSTNAME}/redis.conf"
            redis-server $REDIS_DIR/${PORT}/conf/${HOSTNAME}/redis.conf
        fi
      {{- end }}
        if [[ $? -eq 0 ]]
        then
            echo "Succeed to start the ${counter}th redis server on port ${PORT}"
        else
            echo "Failed to start the ${counter}th redis server on port ${PORT}"
            exit 1
        fi
        #double check whether it is running
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
            fi
            sleep 1
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
        host=${cluster_nodes[$(( $index * 3 ))]}
        server=${cluster_nodes[$(( $index * 3 + 1 ))]}
        port=${cluster_nodes[$(( $index * 3 + 2 ))]}
        if [[ "${host}" == "${HOSTNAME}" ]]
        then
            echo "The redis server(${HOSTNAME}:${port}) is the member of the redis cluster(${cluster_name}). Check whether it was created or not."
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
                    echo "The nodes file(${nodes_file}) contains ${lines} nodes, the redis cluster should be created.wait 1 second and check again."
                    sleep 1
                    continue
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
    echo "The redis server(${HOSTNAME}) is not belonging to the redis cluster(${cluster_name})."
    return 0
}

function precheck(){
    echo "Check whether all redis nodes are running"
    local index=0
    local server=""
    local port=0
    while [[ $index -lt $cluster_size ]]
    do
        server=${cluster_nodes[$(( $index * 3 + 1 ))]}
        port=${cluster_nodes[$(( $index * 3 + 2 ))]}
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
                echo "The redis server(${server}:${port}) is not running,waiting"
                sleep 2
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
            echo "The redis server(${server}:${port}) is running and ready to join the redis cluster(${cluster_name})."
            break
        done
        ((index++))
    done
    echo "All related redis servers are up and ready to join the redis cluster(${cluster_name})"
    return 0
}

#check the clusters one by one, create it if required
#find the cluster configuration
{{- range $i,$redis_cluster := $.Values.redis.redisClusters | default dict }}
cluster_name={{ print "${" $redis_cluster.name "_name}" }}
cluster_nodes={{ print "( \"${" $redis_cluster.name "_nodes[@]}\" )" }}
cluster_size={{ print "${" $redis_cluster.name "_size}" }}
cluster_slaves={{ print "${" $redis_cluster.name "_slaves}" }}
cluster_groups={{ print "${" $redis_cluster.name "_groups}" }}
cluster_persistent={{ print "${" $redis_cluster.name "_persistent}" }}
master_nodes_str={{ print "${" $redis_cluster.name "_nodes_str}" }}

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
        echo "Try to create the cluster for the redis server(${cluster_nodes[1]}:${cluster_nodes[2]} without replicas)"
        if [[ "${PASSWORDS["${cluster_nodes[2]}"]}" == "" ]]
        then
            redis-cli --cluster create ${master_nodes_str} --cluster-yes 
        else
            echo ${PASSWORDS["${cluster_nodes[2]}"]} | redis-cli --askpass --cluster create ${master_nodes_str} --cluster-yes
        fi
        status=$?
        if [[ $status -ne 0 ]]
        then
            echo "Failed to create the redis cluster(${cluster_name})"
            exit 1
        fi
        echo "Succeed to create the redis cluster(${cluster_name}) without replicas"
        echo "Start to add the replicas to redis cluster(${cluster_name})"

        index=0
        while [[ ${index} -lt ${cluster_groups} ]]
        do
            master_server=${cluster_nodes[$(( $index * 3 + 1 ))]}
            master_port=${cluster_nodes[$(( $index * 3 + 2 ))]}

            if [[ "${PASSWORDS["${master_port}"]}" == "" ]]
            then
                res=$(redis-cli -c -h ${master_server} -p ${master_port} cluster myid 2>&1)
            else
                res=$(echo ${PASSWORDS["${master_port}"]} | redis-cli --askpass -c -h ${master_server} -p ${master_port} cluster myid 2>&1)
            fi
            status=$?
            if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]] || [[ $res = *ERR* ]]
            then 
                echo "Failed to retrieve the cluster id from master server(${master_server}:${master_port}) )"
                exit 1
            fi
            master_id=${res}
            echo "Succeed to retrieve the cluster id(${master_id}) from master server(${master_server}:${master_port}) )"

            j=1
            while [[ $j -le ${cluster_slaves} ]]
            do
                slave_index=$((($index + $j * $cluster_groups) % ${cluster_size}))
                slave_server=${cluster_nodes[$(( $slave_index * 3 + 1 ))]}
                slave_port=${cluster_nodes[$(( $slave_index * 3 + 2 ))]}
                echo "Start to let slave server(${slave_server}:${slave_port}) meet with master server(${master_server}:${master_port})"
                while [[ true ]]
                do
                    if [[ "${PASSWORDS["${slave_port}"]}" == "" ]]
                    then
                        res=$(redis-cli -c -h ${slave_server} -p ${slave_port} cluster meet ${master_server} ${master_port} 2>&1)
                    else
                        res=$(echo ${PASSWORDS["${slave_port}"]} | redis-cli --askpass -c -h ${slave_server} -p ${slave_port} cluster meet ${master_server} ${master_port} 2>&1)
                    fi
                    status=$?
                    if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]] || [[ $res = *ERR* ]]
                    then 
                        echo "Failed to let slave server(${slave_server}:${slave_port}) meet with master server(${master_server}:${master_port}).res=${res}"
                        sleep 1
                        continue
                    else
                        break
                    fi
                done
                while [[ true ]]
                do
                    if [[ "${PASSWORDS["${slave_port}"]}" == "" ]]
                    then
                        res=$(redis-cli -c -h ${slave_server} -p ${slave_port} cluster nodes 2>&1)
                    else
                        res=$(echo ${PASSWORDS["${slave_port}"]} | redis-cli --askpass -c -h ${slave_server} -p ${slave_port} cluster nodes 2>&1)
                    fi
                    status=$?
                    if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]] || [[ $res = *ERR* ]]
                    then 
                        echo "Failed to retrive the cluster nodes from server(${slave_server}:${slave_port}) )"
                        exit 1
                    fi
                    lines=$(echo -e "${res}" | wc -l)
                    if [[ ${lines} -eq 1 ]]
                    then
                        echo -e "The server(${slave_server}:${slave_port}) meeting with master server(${master_server}:${master_port}) is processing.)"
                        sleep 1
                    else
                        break
                    fi
                done
                echo "Start to add the slave server(${slave_server}:${slave_port}) to the master server(${master_server}:${master_port})"
                while [[ true ]]
                do
                    if [[ "${PASSWORDS["${slave_port}"]}" == "" ]]
                    then
                        res=$(redis-cli -c -h ${slave_server} -p ${slave_port} cluster replicate ${master_id} 2>&1)
                    else
                        res=$(echo ${PASSWORDS["${slave_port}"]} | redis-cli --askpass -c -h ${slave_server} -p ${slave_port} cluster replicate ${master_id} 2>&1)
                    fi
                    status=$?
                    if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]] || [[ $res = *ERR* ]]
                    then 
                        echo "Failed to add the slave server(${slave_server}:${slave_port}) to the master server(${master_server}:${master_port}), res=${res}"
                        sleep 1
                        continue
                    else
                        break
                    fi
                done
                
                echo "Check whether the slave server(${slave_server}:${slave_port}) ) was added as slave server of the master server(${master_server}:${master_port})"
                while [[ true ]]
                do
                    if [[ "${PASSWORDS["${slave_port}"]}" == "" ]]
                    then
                        res=$(redis-cli -c -h ${slave_server} -p ${slave_port} cluster nodes 2>&1)
                    else
                        res=$(echo ${PASSWORDS["${slave_port}"]} | redis-cli --askpass -c -h ${slave_server} -p ${slave_port} cluster nodes 2>&1)
                    fi
                    status=$?
                    if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]] || [[ $res = *ERR* ]]
                    then 
                        echo "Failed to retrieve the cluster nodes from the slave server(${slave_server}:${slave_port}) ).res=${res}"
                        exit 1
                    fi
                    lines=$(echo -e "$res" | grep "myself" | grep "slave" | wc -l)
                    if [[ ${lines} -ne 1 ]]
                    then
                        echo -e "Add the slave server(${slave_server}:${slave_port}) to the master server(${master_server}:${master_port}) is processing.\n${res}"
                        sleep 1
                    else
                        break
                    fi
                done
                echo "Succeed to add the slave server(${slave_server}:${slave_port}) to the master server(${master_server}:${master_port})"
                ((j++))
            done
            ((index++))
        done

        echo "Double check whether the cluster(${cluster_name}) has been created"
        while [[ true ]]
        do
            if [[ "${PASSWORDS["${cluster_nodes[2]}"]}" == "" ]]
            then
                res=$(redis-cli -c -h ${cluster_nodes[1]} -p ${cluster_nodes[2]} cluster info 2>&1)
            else
                res=$(echo ${PASSWORDS["${cluster_nodes[2]}"]} | redis-cli -c --askpass -h ${cluster_nodes[1]} -p ${cluster_nodes[2]} cluster info 2>&1)
            fi
            status=$?
            if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]] || [[ $res = *ERR* ]]
            then
                echo "The redis server(${cluster_nodes[1]}:${cluster_nodes[2]}) is not ready.res=${res}"
                exit 1
            fi
            res=$(echo "$res" | grep "cluster_state")
            if [[ $res = *cluster_state:ok* ]]
            then
                echo "The redis cluster(${cluster_name}) is ready"
                break
            fi
            sleep 1
        done

        echo "Save the configuration files"
        index=0
        while [[ ${index} -lt ${cluster_size} ]]
        do
            server=${cluster_nodes[$(( $index * 3 + 1 ))]}
            port=${cluster_nodes[$(( $index * 3 + 2 ))]}
            if [[ "${PASSWORDS["${port}"]}" == "" ]]
            then
                res=$(redis-cli -c -h ${server} -p ${port} cluster saveconfig 2>&1)
            else
                res=$(echo ${PASSWORDS["${port}"]} | redis-cli -c --askpass -h ${server} -p ${port} cluster saveconfig 2>&1)
            fi
            status=$?
            if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]] || [[ $res = *ERR* ]]
            then
                echo "Failed to save the configuation of the server(${server}:${port}).res=${res}"
                exit 1
            else
                echo "Succeed to save the configuation of the server(${server}:${port})"
            fi
            ((index++))
        done

    fi
fi
{{- end }}

/bin/bash
exit 0
{{- end }}
