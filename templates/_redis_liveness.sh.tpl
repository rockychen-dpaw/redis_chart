{{- define "redis.redis_liveness" }}#!/bin/bash

{{- template "redis.base_script" }}

{{- $servers := $.Values.redis.servers | default 1 | int }}
{{- $replicas := $.Values.redis.replicas | default 1 | int }}

#reset master node if required
hour=$(date +"%-H")
counter=1
currentlogfile="redis_$(date +"%Y%m%d-%H%M%S").log"
while [[ $counter -le $SERVERS ]]
do
    #get the redis server home dir
    {{- if eq $servers 1 }}
    serverdir="${REDIS_DIR}"
    {{- else }}
    serverdir="${REDIS_DIR}/${PORT}"
    {{- end }}
    
    #manage the redis log file
    redislog="${serverdir}/logs/redis.log"
    logfile_added=0
    res=$(ls "${serverdir}/logs" | sort -rs )
    logfile=""
    #find the latest today's log file
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
        #can not find logfile, use the firstlogfile 
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
    #check whether the current redis server is a master server
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
        #it is a master server
        #switch to master if it is not the master
        #before switch, should guarantee all the data are synced
        #first check whether this server is the master or not
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
        #not checked before, means this redis server is not belonging to a redis cluster or it is not a master 
        check whether it is online 
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

