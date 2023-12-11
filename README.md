# Redis/Redis Cluster
A helm chart to deploy redis or redis cluster to kubernetes
## How it works
This chart can deploy multiple redis workloads, each workload can have multiple replicas and each replica can run multiple redis servers with different port
### Redis
Deploy single redis server or multiple redis servers to kubernetes
#### The objects created in kubernetes
    1. StatefulSets: The workloads to run the redis servers. A release can create multiple statefulsets, and each statefulset can have multiple replicas, each statefulset replica can run multiple redis servers.
    2. Persistent Volumes: If redis server supports persistent or in redis cluster mode, a persistent volume should be required.
    3. Services
        a. A cluster service with hardcoded ip addresses points to a replica instance
        b. A headless service for each statefulset.
    4. Pod Disruption Budget: A pod disrution budget is created for each statefulset if replicas is greater than 1
#### Configuration
    redis:
      image: "redis:7.2.2"             #The redis image
      pidfolder: "/data"               #The folder where to place the pid file; Optional, default value is "/data"
      servers: 2                       #The number of redis servers running in each replica; Optional, default value is 1
      replicas: 2                      #The replicas of redis workload; Optional, default value is 1
      port: 6379                       #The listening port of the first redis server; Optional, default value is 6379; The listening port of the next redis server is the listening port of the current redis server plus 1
      reset: false                     #Empty the redis data folder which includes redis persistent files and cluster nodes file 'nodes.conf' if reset is true; Optional, default value is false
      maxlogfilesize: 1048576          #The maximum size of redis log file; Optional, default value is 1048576
      maxlogfiles: 30                  #The maximum number of redis log files; Optional, default value is 10
      maxstartatfiles: 30              #The maximum number of startat files; Optional, default value is 30
      volume:                          #Configure the persisten volume, Optional
        storage: 1Gi                   #The size of the persistent volume.
      startupProbe:                    #Configure the startupProbe of the redis workload
        failureThreshold: 30
        successThreshold: 1
        initialDelaySeconds: 0
        timeoutSeconds: 1
        periodSeconds: 1
      livenessProbe:                   #Configure the livenessProbe of the redis workload
        failureThreshold: 2
        successThreshold: 1
        initialDelaySeconds: 1
        timeoutSeconds: 1
        periodSeconds: 2
      topologySpreadConstraints:       #Configure the topology spread constraints used by redis workloads. The first constraint controls the spread of the replicas of the workload; The other constraints control the spread of the master nodes for the cluster; Optional
      - topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
      envs:                            #The extra environments of redis workloads
      - name: "TZ"                     #Set the timezone of redis workload
        value: "Australia/Perth"
      workloads:                       #Configure the number of redis workloads
      - clusterips:                    #Configure the cluster service ip addresses of the replicas of the current workload; the number of configured cluster ip addresses should be the same as the value of the item "replicas"
        - 10.0.35.126                  
        - 10.0.35.127
      - clusterips:
        - 10.0.35.128
        - 10.0.35.129
      - clusterips:
        - 10.0.35.130
        - 10.0.35.131
      redis.conf:                      #The common configuration used hy all redis servers, all items with the prefix "_" are not redis configuration and are settings used by chart.
        save: ""
        appendonly: "yes"
        appendfsync: "everysec"
        auto-aof-rewrite-percentage: 100
        auto-aof-rewrite-min-size: 64mb
        aof-load-truncated: "yes"
        cluster-enabled: "yes"
        cluster-require-full-coverage: "no"
        cluster-replica-no-failover: "no"
        cluster-allow-reads-when-down: "yes"
        cluster-allow-replica-migration: "no"
        cluster-migration-barrier: 1
        cluster-replica-validity-factor: 0
      redis_6379.conf:                #The configuration for all redis servers with listening port '6379' , all items with the prefix "_" are not redis configuration and are settings used by chart.
        requirepass: "12345"
        masterauth: "12345"
        cluster-node-timeout: 15000
        _clear_data_if_fix_failed: true #Clear the persistent files if the persistent files are corrupted,and can't be fixed.

### Redis Cluster
Create single redis cluster or multiple redis clusters from redis servers
#### The objects created in kubernetes
    1. Services
        a. A cluster service points to all instances belonging to a redis cluster

#### Configuration
    redis:
      redisClusters:                     #Configure all the clusters
      - name: "default"                  #The name of the cluster, "default" is a special name, means the default redis cluster
        servers: #index is 1 based       
        #Configure all the nodes of the redis cluster. Each node is configured as 'redis[workload-index]-[replica-index]:[port]'; workload-index is 1 based, and prefilled with 0 if required; replica-index is 0 based. 
        #The number of the redis cluster groups is the number of nodes dividing 'clusterReplicas'
        #The size of the redis cluster group is 'clusterReplicas' plus one.
        #The redis server nodes are ordered as master nodes, first slave nodes, second slave node and so on.
        - "redis1-0:6379"
        - "redis2-0:6379"
        - "redis3-0:6379"
        - "redis1-1:6379"
        - "redis2-1:6379"
        - "redis3-1:6379"
        clusterReplicas: 1               #The replicas of the redis cluster; Optional, default value is 1
        resetMasterNodes: true           #Redis cluster will try to reset the configured master node as cluster master node if it is not a cluster master node; Optional, default value is false
        resetStart: 0                    #hour 0-23 inclusive; Optional, default value is 0
        resetEnd: 23                     #hour 0-23 exclusive; Optional, default value is 24
