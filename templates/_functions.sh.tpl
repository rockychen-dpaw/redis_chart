{{- define "redis.functions" }}#!/usr/bin/env bash
function log(){
    echo "$2"
    if [[ ! "${redis_start_file}" == "" ]];then 
        echo "$(date +'%Y-%m-%d %H:%M:%S %Z') $2" >> "$1/data/${redis_start_file}" 
    fi
}
{{- end }}
