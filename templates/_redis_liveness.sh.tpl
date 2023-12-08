{{- define "redis.redis_liveness" }}#!/bin/bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REDIS_DIR=$( cd -- "$( dirname -- "${SCRIPT_DIR}" )" &> /dev/null && pwd )

PORT={{ $.Values.redis.port | default 6379 | int }}
SERVERS={{ $.Values.redis.servers | default 1 | int }}

{{ $servers := $.Values.redis.servers | default 1 | int }}
{{- $cluster_size := 0 }}
{{- $cluster_groups := 0 }}
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
{{ $redis_cluster.name}}_nodes=()
{{ $redis_cluster.name}}_name={{ $redis_cluster.name }}
    {{- $cluster_groups = div $cluster_size (add ($redis_cluster.clusterReplicas | default 1) 1) | int }}
    {{- range $j,$redis_node := $redis_cluster.servers }}
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
            {{- end }}
        {{- end}}
    {{- end }}
{{ $redis_cluster.name}}_size={{ $cluster_size }}
{{ $redis_cluster.name}}_slaves={{ $redis_cluster.clusterReplicas | default 1 }}
{{ $redis_cluster.name}}_groups={{ div $cluster_size (add ($redis_cluster.clusterReplicas | default 1) 1) | int }}
{{ $redis_cluster.name}}_persistent={{ $persistent }}
{{ $redis_cluster.name}}_reset_start={{ $redis_cluster.resetStart | default 0 }}
{{ $redis_cluster.name}}_reset_end={{ $redis_cluster.resetEnd | default 24 }}
{{- if ($redis_cluster.resetMasterNodes | default false) }}
{{ $redis_cluster.name}}_reset_master=1
{{- else }}
{{ $redis_cluster.name}}_reset_master=0
{{- end }}

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

#reset master node if required
hour=$(date +"%-H")
PORT={{ $.Values.redis.port | default 6379 | int }}
counter=1
currentlogfile="redis_$(date +"%Y%m%d-%H%M%S").log"
day=$(date +"%Y%m%d")
firstlogfile="redis_${day}-000000.log"
while [[ $counter -le $SERVERS ]]
do
    {{- if eq $servers 1 }}
    serverdir="${REDIS_DIR}"
    {{- else }}
    serverdir="${REDIS_DIR}/${PORT}"
    {{- end }}

    redislog="${serverdir}/logs/redis.log"
    logfile_added=0
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
        rm -rf "${redislog}"
        ln -s "${logfile}" "${redislog}"
        logfile_added=1
    else
        logfile=$(realpath "${redislog}")
        filesize=$(stat -c '%s' "${logfile}")
        if [[ ${filesize} -gt {{ $.Values.redis.maxlogfilesize | default 1048576 | int }} ]]
        then
            logfile="${serverdir}/logs/${currentlogfile}"
            if ! [[ -f "${logfile}" ]]
            then
                touch "${logfile}"
                logfile_added=1
            fi
            rm -rf "${redislog}"
            ln -s "${logfile}" "${redislog}"
        fi
    fi
    
    if [[ ${logfile_added} -eq 1 ]]
    then
        #a new log file added, manage the log files
        maxfiles={{ $.Values.redis.maxlogfiles | default 10 }}
        index=1 # a new logfile was added which is not included in ${res}
        while IFS= read -r file
        do
            if [[ ${file} = redis_*.log ]]
            then
                ((index++))
                if [[ ${index} -gt ${maxfiles} ]]
                then
                    rm -f "${serverdir}/logs/${file}"
                fi
            fi
        done <<< "${res}"
    fi

    is_checked=0
    {{- range $i,$redis_cluster := $.Values.redis.redisClusters | default dict }}
    is_master=0
    if [[ {{ print "${" $redis_cluster.name "_"}}reset_master} -eq 1 ]] && [[ ${hour} -ge {{ print "${" $redis_cluster.name "_"}}reset_start} ]] && [[ ${hour} -lt {{ print "${" $redis_cluster.name "_"}}reset_end} ]]
    then
        #reset master nodes enabled
        index=0
        while [[ $index -lt {{ print "${" $redis_cluster.name "_groups}" }} ]]
        do
            server={{ print "${" $redis_cluster.name "_nodes[$(( $index * 3 ))]}" }}
            port={{ print "${" $redis_cluster.name "_nodes[$(( $index * 3 + 2 ))]}" }}
            if [[ "${server}" = "${HOSTNAME}" ]] && [[ ${port} -eq ${PORT} ]]
            then
                #is master node
                is_master=1
                break
            fi
            ((index++))
        done
    fi
    if [[ ${is_master} -eq 1 ]]
    then
        #switch to master if it is not the master
        echo "The redis server(${HOSTNAME}:${PORT}) should be a master node of the redis cluser({{ $redis_cluster.name }})"
        is_checked=1
        if [[ "${PASSWORDS["${PORT}"]}" == "" ]]
        then
            res=$(redis-cli -c -p ${PORT} info replication 2>&1)
        else
            res=$(echo ${PASSWORDS["${PORT}"]} | redis-cli --askpass -c -p ${PORT} info replication 2>&1)
        fi
        status=$?
        if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]]
        then 
            echo "The server(${HOSTNAME}:${PORT}) is offline."
            exit 1
        fi
        if [[ $res = *ERR* ]]
        then 
            echo "The server(${HOSTNAME}:${PORT}) doesn't support cluster feature"
            exit 1
        fi
        is_slave=$(echo -e "$res" | grep "role" | grep "slave" | wc -l )
        if [[ ${is_slave} -eq 1 ]]
        then
            #not the master, switch to master node
            #check the sync status
            master_host=$(echo -e "$res" | grep "master_host" | sed -E "s/[^0-9\.]//g" )
            master_port=$(echo -e "$res" | grep "master_port" | sed -E "s/[^0-9]//g" )
            if [[ "${PASSWORDS["${master_port}"]}" == "" ]]
            then
                master_res=$(redis-cli -c -p ${master_port} -h ${master_host} info replication 2>&1)
            else
                master_res=$(echo ${PASSWORDS["${master_port}"]} | redis-cli --askpass -c -p ${master_port} -h ${master_host} info replication 2>&1)
            fi
            status=$?
            if [[ ${status} -ne 0 ]] || [[ ${master_res} = *"Connection refused"* ]]
            then 
                echo "The server(${master_host}:${master_port}) is offline."
                exit 0
            fi
            if [[ ${master_res} = *ERR* ]]
            then 
                echo "The server(${master_host}:${master_port}) doesn't support cluster feature"
                exit 0
            fi

            master_repl_offset=$(echo -e "${master_res}" | grep "master_repl_offset" | sed 's/[^0-9]//g' )
            slave_repl_offset=$(echo -e "${res}" | grep "slave_repl_offset" | sed 's/[^0-9]//g' )
            if [[ "${master_repl_offset}" = "" ]] || [[ "${slave_repl_offset}" = "" ]]
            then
                diff=0
            else
                diff=$((${master_repl_offset} - ${slave_repl_offset}))
            fi
            if [[ ${diff} -lt 1 ]]
            then
                #already synced,switch
                echo "Try to switch the server(${HOSTNAME}:${PORT}) to master node. master_repl_offset=${master_repl_offset}, slave_repl_offset=${slave_repl_offset}"
                if [[ "${PASSWORDS["${PORT}"]}" == "" ]]
                then
                    res=$(redis-cli -c -p ${PORT} cluster failover takeover 2>&1)
                else
                    res=$(echo ${PASSWORDS["${PORT}"]} | redis-cli --askpass -c -p ${PORT} cluster failover takeover 2>&1)
                fi
                status=$?
                if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]] 
                then 
                    echo "The server(${HOSTNAME}:${PORT}) is offline."
                    exit 1
                fi
                if [[ $res = *ERR* ]]
                then 
                    echo "Failed to switch the server(${HOSTNAME}:${PORT}) to master "
                else
                    echo "Succeed to switch the server(${HOSTNAME}:${PORT}) to master "
                fi
            else
                echo "Too much data need to be sync, try next time. master_repl_offset=${master_repl_offset}, slave_repl_offset=${slave_repl_offset}"
            fi
        else
            echo "The redis server(${HOSTNAME}:${PORT}) is online and already a master node"
        fi
    fi
    {{- end }}
    if [[ ${is_checked} -eq 0 ]]
    then
        #check whether it is online 
        if [[ "${PASSWORDS["$PORT"]}" == "" ]]
        then
            res=$(redis-cli -p $PORT ping 2>&1)
        else
            res=$(echo ${PASSWORDS["$PORT"]} | redis-cli --askpass -p $PORT ping 2>&1)
        fi
        status=$?
        if [[ $status -ne 0 ]] || [[ $res = *"Connection refused"* ]] || [[ "$res" != "PONG" ]]
        then
            echo "The redis server(${HOSTNAME}:${PORT}) is offline"
            exit 1
        else
            echo "The redis server(${HOSTNAME}:${PORT}) is online"
        fi
    fi

    ((counter++))
    ((PORT++))
done

exit 0
{{- end }}

