{{- define "redis.base_script" }}#!/bin/bash
#convert the redis config and redis cluster config into bash script variables
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REDIS_DIR=$( cd -- "$( dirname -- "${SCRIPT_DIR}" )" &> /dev/null && pwd )

PORT={{ $.Values.redis.port | default 6379 | int }}
SERVERS={{ $.Values.redis.servers | default 1 | int }}

{{- $servers := $.Values.redis.servers | default 1 | int }}

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
declare -A CLEAR_IF_FIX_FAILED
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
{{ if (get $redisport_conf "_clear_data_if_fix_failed") | default (get $redis_conf "_clear_data_if_fix_failed") | default false }}
CLEAR_IF_FIX_FAILED[{{ $port | quote }}]=1
{{- else }}
CLEAR_IF_FIX_FAILED[{{ $port | quote }}]=0
{{- end }}
{{- end }}

day=$(date +"%Y%m%d")
firstlogfile="redis_${day}-000000.log"

{{- end }} # the end of "define "redis.start_redis"
