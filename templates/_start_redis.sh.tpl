{{- define "redis.start_redis" }}#!/bin/bash
#start redis, will create the redis cluster if required

{{- template "redis.base_script" }}

{{- $servers := $.Values.redis.servers | default 1 | int }}
{{- $replicas := $.Values.redis.replicas | default 1 | int }}

function start_redis(){
    #start the redis server, if failed,  return 128
    {{- if eq $replicas 1 }}
    echo "Start the redis server: redis-server ${serverdir}/conf/redis.conf"
    res=$(redis-server ${serverdir}/conf/redis.conf)
    {{- else }}
    echo "Start the redis server: redis-server ${serverdir}/conf/${HOSTNAME}/redis.conf"
    res=$(redis-server ${serverdir}/conf/${HOSTNAME}/redis.conf)
    {{- end }}
    if [[ $? -ne 0 ]]
    then
        return 128
    fi

    echo "Check whether the redis server(127.0.0.1:${PORT}) is started successfully..."
    #try 5 times, check interval is 1 second
    attempts=5
    while [[ true ]]
    do
        if [[ "${PASSWORDS["$PORT"]}" == "" ]]
        then
            res=$(redis-cli -p $PORT ping 2>&1)
        else
            res=$(echo ${PASSWORDS["$PORT"]} | redis-cli --askpass -p $PORT ping 2>&1)
        fi
        status=$?
        if [[ $status -eq 0 ]] && [[ "${res}" = "PONG" ]]
        then
            #redis is online and ready to use
            echo "The redis server(127.0.0.1:${PORT}) is ready to use."
            #create a startup file for later checking
            file=${serverdir}/data/redis_started_at_$(date +"%Y%m%d-%H%M%S")
            touch ${file}
            echo "create file ${file}"

            #manage the redis_started_at files, only keep the latest configured number of startup files.
            res=$(ls "${serverdir}/data" | sort -rs )
            maxfiles={{ $.Values.redis.maxstartatfiles | default 30 }}
            index=0
            while IFS= read -r file
            do
                if [[ ${file} = redis_started_at_* ]]
                then
                    ((index++))
                    if [[ ${index} -gt ${maxfiles} ]]
                    then
                       #delete the outdated startup files
                       rm -f "${serverdir}/data/${file}"
                    fi
                fi
            done <<< "${res}"

            echo "The redis server(127.0.0.1:${PORT}) is ready to use."
            return 0
        fi
        if [[ ${attempts} -eq -1 ]]
        then
            # try unlimited times
            sleep 1
        elif [[ ${attempts} -gt 0 ]]
        then
            sleep 1
            ((attempts--))
        else
            echo "Failed to start the redis server(127.0.0.1:${PORT})."
            return 128
        fi
    done
    echo "Failed to start the redis server(127.0.0.1:${PORT})."
    return 128
}

function switch_one_slave_to_master(){
    #switch one slave to master because the current master is offline
    #try to find the master node  from the next node of the current redis server, if reach the end, and then start from the begining.
    #the logic will search all nodes in the redis cluster group, except the current redis server
    #return 0 if already have one master
    #return 1 if switch succeed
    #return 128 if failed
    j=1
    new_master_index=-1
    #try to find the index of the slave which will be switched to master
    #if a slave is already the master, then no need to switch.
    while [[ $j -le ${cluster_slaves} ]]
    do
        other_index=$(((${clusternode_index} + $j * $cluster_groups) % ${cluster_size}))
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
        echo "The cluster(${cluster_name}) has no online master node right now.try to switch the server(${new_master_server}:${new_master_port}) to master."
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
            return 128
        else
            #check whether switch is succeed or not.
            attempts=5
            msg=""
            while [[ true ]]
            do
                if [[ "${PASSWORDS["${new_master_port}"]}" == "" ]]
                then
                    res=$(redis-cli -h ${new_master_server} -c -p ${new_master_port} cluster nodes 2>&1)
                else
                    res=$(echo ${PASSWORDS["${new_master_port}"]} | redis-cli --askpass -c -h ${new_master_server} -p ${new_master_port} cluster nodes 2>&1)
                fi
                status=$?
                if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]] || [[ $res = *ERR* ]]
                then 
                    msg="Failed to switch the server(${new_master_server}:${new_master_port}) to master node."
                else
                    nodes=$(echo -e "$res" | wc -l )
                    if [[ $nodes -lt 2 ]]
                    then
                        msg="Failed to switch the server(${new_master_server}:${new_master_port}) to master node."
                    else
                        is_master=$(echo -e "$res" | grep "myself" | grep "master" | wc -l )
                        if [[ ${is_master} -eq 1 ]]
                        then
                            echo "Succeed to switch the server(${new_master_server}:${new_master_port}) to master node."
                            return 1
                        else
                            msg="Failed to switch the server(${new_master_server}:${new_master_port}) to master node."
                        fi
                    fi
                fi
                ((attempts--))
                if [[ ${attempts} -gt 0 ]]
                then
                    sleep 1
                else
                    echo ${msg}
                    return 128
                fi
            done
        fi
    fi
    return 0
}

#try to start the redis server, will switch the master node if necessary
counter=1
while [[ $counter -le $SERVERS ]]
do
    #check whether redis server is online or not
    if [[ "${PASSWORDS["$PORT"]}" == "" ]]
    then
        res=$(redis-cli -p $PORT ping 2>&1)
    else
        res=$(echo ${PASSWORDS["$PORT"]} | redis-cli --askpass -p $PORT ping 2>&1)
    fi
    status=$?
    if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]] || [[ "$res" != "PONG" ]]
    then
        #redis server with the port $PORT is not started
        #switch the redis master if this server is belong to a redis cluster which is persistent disabled, and also the corresponding redis server has not taken over yet.
        switch_required=0
        switched=0
        clusternode_index=-1
        cluster_name=""
        cluster_nodes=""
        cluster_size=0
        cluster_slaves=0
        cluster_groups=0
        cluster_persistent=0
        #find the redis cluster which this redis server belongs to.
        #if it is not belonging to any redis cluster, the clusternode_index should be -1
        {{- range $i,$redis_cluster := $.Values.redis.redisClusters | default dict }}
        cluster_nodes={{ print "( \"${" $redis_cluster.name "_nodes[@]}\" )" }}  
        cluster_size={{ print "${" $redis_cluster.name "_size}" }}

        #cluster doesn't support persistent. so master switch is required 
        index=0
        while [[ $index -lt ${cluster_size} ]]
        do
            server=${cluster_nodes[$(( $index * 3 ))]}
            port=${cluster_nodes[$(( $index * 3 + 2 ))]}
            if [[ "${server}" == "${HOSTNAME}" ]] && [[ ${port} -eq ${PORT} ]]
            then
                clusternode_index=${index}
                cluster_name={{ print "${" $redis_cluster.name "_name}" }}
                cluster_slaves={{ print "${" $redis_cluster.name "_slaves}" }}
                cluster_groups={{ print "${" $redis_cluster.name "_groups}" }}
                cluster_persistent={{ print "${" $redis_cluster.name "_persistent}" }}
                break
            fi
            ((index++))
        done
        {{- end}}

        if [[ ${clusternode_index} -ge 0 ]]
        then
            echo "The redis server(127.0.0.1:${PORT}) has joined the redis cluster({${cluster_name}})"
            if [[ ${cluster_persistent} -eq 0 ]]
            then
                echo "The redis cluster($cluster_name) doesn't support persistent, try to choose a slave node as new master node"
                switch_one_slave_to_master
                status=$?
                if [[ $status -lt 128 ]]
                then
                    #switched successfully
                    switched=1
                else
                    #switch failed
                    switched=0
                fi
            else
                echo "The redis cluster($cluster_name) supports persistent, no need to switch the slave node to master node at this stage"
                switched=0
            fi
        fi

        #create a daily based redis log file and use soft link to link the log file to redislog file
        {{- if eq $servers 1 }}
        serverdir="${REDIS_DIR}"
        {{- else }}
        serverdir="${REDIS_DIR}/${PORT}"
        {{- end }}
        redislog="${serverdir}/logs/redis.log"
        if [[ -f "${redislog}" ]] && ! [[ -L "${redislog}" ]]
        then
            #normal  redis log file, change it to symbolic file
            logfile="${serverdir}/logs/${firstlogfile}"
            mv "${redislog}" "${logfile}"
            ln -s "${logfile}" "${redislog}"
        else 
            res=$(ls "${serverdir}/logs" | sort -rs )
            logfile=""
            while IFS= read -r file
            do
                if [[ ${file} = redis_*.log ]]
                then
                    if [[ ${file} = redis_${day}-*.log ]]
                    then
                        logfile=${file}
                    fi
                    break
                fi
            done <<< "${res}"

            if [[ "${logfile}" == "" ]]
            then
                logfile="${serverdir}/logs/${firstlogfile}"
                touch "${logfile}"
                if [[ -e "${redislog}" ]]
                then
                    rm -rf "${redislog}"
                fi
            elif ! [[ -L "${redislog}" ]]
            then
                if [[ -e "${redislog}" ]]
                then
                    rm -f "${redislog}"
                fi
            fi
            if ! [[ -e "${redislog}" ]]
            then
                ln -s "${logfile}" "${redislog}" 
            fi
        fi
  
        #start redis server
        start_redis
        status=$?
        if [[ ${status} -gt 127 ]]
        then
            #start failed, try to recovery
            {{- if eq $servers 1 }}
            data_dir=${REDIS_DIR}/data/appendonlydir
            {{- else }}
            data_dir=${REDIS_DIR}/${PORT}/data/appendonlydir
            {{- end }}
            if [[ ${clusternode_index} -eq -1 ]] && [[ $res ==  *Bad\ file\ format\ reading\ the\ append\ only\ file:* ]]
            then
                #this redis server is not belonging to any redis cluster
                #corrupted append only file, try to fix it
                # try to fix the append only file if not in cluster mode
                succeed=1
                for f in "${data_dir}"/*
                do
                    if [[ ${f} == *appendonly.aof.manifest ]]
                    then
                        continue
                    fi
                    echo "Check and fix the aof file(${f}) if required"
                    echo "y" | redis-check-aof --fix "${f}"
                    if [[ $? -ne 0 ]]
                    then
                        echo "Failed to fix the file(${f})"
                        succeed=0
                    else
                        echo "The file(${f}) is valid or was fixed successfully"
                    fi
                done
                if [[ ${succeed} -eq 0 ]] && [[ ${CLEAR_IF_FIX_FAILED["$PORT"]} -eq 1 ]]
                then
                    #failed to fix the aof file, remove all aof files
                    echo "Remove all aof file from folder ${data_dir}"
                    rm -rf ${data_dir}/*
                fi
            elif [[ ${CLEAR_IF_FIX_FAILED["$PORT"]} -eq 1 ]]
            then
                #the redis server is belonging to a redis cluster, 
                #remove all aof files
                echo "Remove all aof file from folder ${data_dir}"
                rm -rf ${data_dir}/*
            else
                #can not start the redis server
                exit 1
            fi
            #start the redis again
            if [[ ${clusternode_index} -ge 0 ]] && [[ ${switched} -eq 0 ]]
            then
                #in cluster mode, not swithed before,try to switched a slave node to master because the appenonly files were cleared
                echo "The appendonly files were cleared. try to choose a slave node as new master node for cluster(${cluster_name})"
                switch_one_slave_to_master
            fi
            start_redis
        fi
    else
        echo "The ${counter}th redis server on port ${PORT} has already been started"
    fi
    ((counter++))
    ((PORT++))
done

function wait_until_rediscluster_in_initial_status(){
   #check whether the redis cluster has the initial status
   while [[ true ]]
   do
       
       index=0
       succeed=1
       while [[ $index -lt $cluster_size ]]
       do
           redis_host=${cluster_nodes[$(( $index * 3 ))]}
           redis_server=${cluster_nodes[$(( $index * 3 + 1 ))]}
           redis_port=${cluster_nodes[$(( $index * 3 + 2 ))]}

           if [[ "${PASSWORDS["${redis_port}"]}" == "" ]];then
               res=$(redis-cli -h ${redis_host} -p ${redis_port} cluster info 2>&1)
           else
               res=$(echo ${PASSWORDS["${redis_port}"]} | redis-cli --askpass -h ${redis_host} -p ${redis_port} cluster info 2>&1)
           fi
           status=$?
           if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]];then
               echo "The redis server(${redis_host}:${redis_port}) is not running,status=${status}"
               succeed=0
               break
           fi
           if [[ $res ==  *ERR* ]];then
               echo "The redis server(${redis_host}:${redis_port}) does not support cluster feature"
               succeed=0
               break
           fi
           res=$(echo "$res" | grep "cluster_state")
           if [[ $res != *cluster_state:ok* ]];then
               echo "The redis server(${redis_host}:${redis_port}) was still not added to the redis cluster(${cluster_name})."
               succeed=0
               break
           fi

           if [[ ${index} -lt ${cluster_groups} ]];then
               should_be_master=1
           else
               should_be_master=0
           fi
           if [[ "${PASSWORDS["${redis_port}"]}" == "" ]];then
               res=$(redis-cli -h ${redis_host} -p ${redis_port} cluster nodes 2>&1)
           else
               res=$(echo ${PASSWORDS["${redis_port}"]} | redis-cli --askpass -h ${redis_host} -p ${redis_port} cluster nodes 2>&1)
           fi
           status=$?
           if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]];then
               # "The redis server(${redis_host}:${redis_port}) is not running,status=${status}"
               succeed=0
               break
           fi
           is_master=$(echo -e "$res" | grep "myself" | grep "master" | wc -l )
           if [[ ${is_master} -ne ${should_be_master} ]];then
               #the current server is not in the initial status,wait
               if [[ ${is_master} -eq 1 ]];then
                   echo "The server(${redis_host}:${redis_port}) is master, but it is configured as slave.can't backup the nodes.conf right now."
               else
                   echo "The server(${redis_host}:${redis_port}) is slave, but it is configured as master.can't backup the nodes.conf right now."
               fi
               succeed=0
               break
           else
               if [[ ${is_master} -eq 1 ]];then
                   echo "The server(${redis_host}:${redis_port}) is master, and it is also configured as master."
               else
                   echo "The server(${redis_host}:${redis_port}) is slave, and it is configured as slave"
               fi
           fi
           ((index++))
       done
       if [[ ${succeed} -eq 0 ]];then
           #failed
           sleep 60
           continue
       fi
       break
   done
}

function check_related_clusters(){
    #check whether the related clusters are created.
    #return 0: redis cluster was created
    #return 1: redis cluster was not created, and the current redis server is the first node, create it now
    #return 2: redis cluster was not created, and the current redis server is not the first node, let the first node create it
    #return 3: redis server is not belonging to any redis cluster
    #return 128, check failed
    local server=""
    local port=0
    local index=0
    index=0
    while [[ $index -lt $cluster_size ]]
    do
        host=${cluster_nodes[$(( $index * 3 ))]}
        server=${cluster_nodes[$(( $index * 3 + 1 ))]}
        port=${cluster_nodes[$(( $index * 3 + 2 ))]}
        {{- if eq $servers 1 }}
        serverdir="${REDIS_DIR}"
        {{- else }}
        serverdir="${REDIS_DIR}/${port}"
        {{- end }}
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
                    return 128
                fi
                if [[ $res ==  *ERR* ]]
                then
                    echo "The redis server(127.0.0.1:${port}) does not support cluster feature"
                    return 128
                fi
                res=$(echo "$res" | grep "cluster_state")
                if [[ $res = *cluster_state:ok* ]]
                then
                    echo "The redis cluster(${cluster_name}) has alreay been created."
                    if [[ ! -f ${serverdir}/data/nodes.conf.bak ]];then
                       #nodes.conf is not backup before,backup now

                       #wait until the redis cluster is in the initial status
                       wait_until_rediscluster_in_initial_status

                       echo "All redis servers are in initial status, backup the nodes.conf"
                       cp ${serverdir}/data/nodes.conf ${serverdir}/data/nodes.conf.bak
                       if [[ $? -eq 0 ]];then
                           echo "Succeed to backup the nodes.conf to ${serverdir}/data/nodes.conf.bak"
                       else
                           echo "Failed to backup the nodes.conf"
                           rm -f ${serverdir}/data/nodes.conf.bak
                       fi
                    fi
                    return 0
                fi

                nodes_file="${serverdir}/data/nodes.conf"
                if ! [[ -f "${nodes_file}" ]]
                then
                    echo "Can't find the nodes.conf.the redis server(127.0.0.1:${port}) does not support cluster feature"
                    return 128
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
                    echo "The redis cluster(${cluster_name}) is not created. create it now.status=${res}"
                    return 1
                else
                    echo "The redis cluster(${cluster_name}) is not created. wait the node(${cluster_nodes[0]}) to create it"

                    #wait until the redis cluster is in the initial status
                    wait_until_rediscluster_in_initial_status

                    echo "redis cluster was create , backup the nodes file" 
                    #this is the first chance to backup the nodes file for the non first node
                    cp -f ${serverdir}/data/nodes.conf ${serverdir}/data/nodes.conf.bak
                    if [[ $? -eq 0 ]];then
                        echo "Succeed to backup the nodes.conf to ${serverdir}/data/nodes.conf.bak"
                    else
                        echo "Failed to backup the nodes.conf"
                        rm -f ${serverdir}/data/nodes.conf.bak
                    fi
                    return 2
                fi
            done
            break
        fi
        ((index++))
    done
    echo "The redis server(${HOSTNAME}) is not belonging to the redis cluster(${cluster_name})."
    return 3
}

function precheck(){
    #check whether all redis server in the redis cluster are running
    #the logic will keep checking unitl all servers are running or check failed
    #return 0:  all servers are running
    #return 128: check failed
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
            #check whether redis server is running
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
                return 128
            fi
            res=$(echo "$res" | grep "cluster_state")
            if [[ $res = *cluster_state:ok* ]]
            then
                echo "The redis server(${server}:${port}) is already belonging to a redis cluster"
                return 128
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
if [[ $status -gt 127 ]]
then
    #failed
    exit 1
fi
if [[ $status -eq 1 ]]
then
    #redis cluster was not created,create it now
    precheck
    staus=$?
    if [[ $status -gt 127 ]]
    then
        #check failed
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
            #get the master_id from redis cluster
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

            #add the slaves one by one
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
                #wait the meet process to finish
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

        #backup the nodes.conf
        #this is the first chance to backup the nodes file for the first node
        {{- if eq $servers 1 }}
        serverdir="${REDIS_DIR}"
        {{- else }}
        port=${cluster_nodes[2]}
        serverdir="${REDIS_DIR}/${port}"
        {{- end }}
        cp -f ${serverdir}/data/nodes.conf ${serverdir}/data/nodes.conf.bak
        if [[ $? -eq 0 ]];then
            echo "Succeed to backup the nodes.conf to ${serverdir}/data/nodes.conf.bak"
        else
            echo "Failed to backup the nodes.conf"
            rm -f ${serverdir}/data/nodes.conf.bak
        fi
    fi
fi
{{- end }} # the end of "check the clusters one by one"

/bin/bash
exit 0
{{- end }} # the end of "define "redis.start_redis"
