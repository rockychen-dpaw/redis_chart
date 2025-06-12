# Redis/Redis Cluster
A helm chart to deploy redis or redis cluster or both to kubernetes
## How it works
This chart can deploy multiple redis workloads, each workload can have muliple instances(replica is greater than 1), and each pod instance can run multiple redis servers with different port
To create a redis cluster, the following rules must be followed.
    1. Each redis cluster group must be corresponding to a workload.
    2. The size of groups must be equal than the replicas of group
    3. All the redis server blonging to a redis cluster must have the same listening port
    4. All the redis server blonging to a redis cluster must have the same configurations.
### Redis
Deploy single redis server or multiple redis servers to kubernetes
#### The objects created in kubernetes
    1. StatefulSets: The workloads to run the redis servers. A release can create multiple statefulsets, and each statefulset can have multiple replicas, each statefulset replica can run multiple redis servers.
    2. Persistent Volumes: If redis server supports persistent or in redis cluster mode, a persistent volume should be required.
    3. Services
        a. A cluster service with hardcoded ip addresses points to a pod instance
        b. A headless service for each statefulset.
    4. Pod Disruption Budget: A pod disrution budget is created for each statefulset if replicas is greater than 1
#### Configuration
    redis:
      image: "redis:7.2.2"             #The redis image
      pidfolder: "/data"               #The folder where to place the pid file; Optional, default value is "/data"
      servers: 2                       #The number of redis servers running in each pod instance; Optional, default value is 1

      #The replicas of redis workload; Optional, default value is 1;
      #If redis cluster is required, the value must be at least 2
      replicas: 2                      #The replicas of redis workload; Optional, default value is 1; if redis cluster is required, the value must be at least 2

      #The listening port of the first redis server; Optional, default value is 6379; 
      #If multile redis servers are running in a single pod instance, the listening ports are the continuous numbers starting from the cofigured port number.
      port: 6379

      #Reset support two scopes:
      #1. string type: reset all redis servers to the reset level
      #2. dict type  : key is the string value of the 'port', value is the reset level.
      #Reset support different levels
      #  DISABLED     : disable reset , default value
      #  ALL          : clean everything. including data, log and nodes.conf
      #  DATA         : only clean persistent data
      #  LOG          : only clean logs
      #  DATA_AND_LOG : clean data and log
      #  NODES        : restore from nodes.conf.bak and also clean data and logs
      reset: "DISABLED"
      maxlogfilesize: 1048576          #The maximum size of redis log file; Optional, default value is 1048576
      maxlogfiles: 30                  #The maximum number of redis log files; Optional, default value is 10
      maxstartatfiles: 30              #The maximum number of startat files; Optional, default value is 30
      resources:
        requests:
          cpu: 50m
          memory: 200Mi
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

      # Config all the workloads belonging to the redis chart
      # Each ip address configured in here is the ip address of the cluster ip service which is used to access redis server
      # Each clusterips setting is a kubernetes stateful workload, which is corresponding to a redis cluster group
      # The number of the ip addresses in a clusterips is the replica of stateful workload, which is also the nodes of a redis cluster group. All stateful's replica should be same
      # The ip addresses should not be changed after redis cluster is created.
      workloads:
        # The number of workload should be equal with the number of redis cluster group
        # The number of ips in clusterips shoule be equal with the replicas of the workload
        # If replicas is 1, can configure the clusterip as key, value
        # - clusterip: 10.0.35.126
        # If replicas is greater than 1, must configure cluterip as list
        # - clusterips
        #   - 10.0.35.126
        #   - 10.0.35.127
      - clusterips:
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

      # Configure redis clusters if redis cluster is required
      redisClusters:
      - name: "default" # the name of the redis cluster
        # One statufule set is redis cluster group; for example. if the statusfule set has 2 replicas , the redis cluster has one master and one slave.
        # Config all redis servers belonging to a redis cluster, the server name is "redis[redis index]-[statefuleset replica index]:[redis port]"
        # Redis index is 1 based, The name of the first redis statefulset is redis1
        # But if has more than 9 redis statefulset, use two digitals in its name, for example, the name of the fist redis statefulset is redis01
        # The statefulset's replica is 0 based.
        # All redis servers with the same port running in replicas of a statefuleset must belong to a redis cluster or not belong to a redis cluster, can't partially belong to a cluster
        # All cluster nodes belong to a redis cluster should have the same port number
        # The order of the servers is redis master servers,  followed by first redis slave servers , and followed by second redis servers, and so on
        servers: 
        - "redis1-0:6379"
        - "redis2-0:6379"
        - "redis3-0:6379" 
        - "redis1-1:6379"
        - "redis2-1:6379"
        - "redis3-1:6379"
        #Config the number of slaves in a redis cluster. 1 means only one slave in a redis cluster.
        clusterReplicas: 1
        #If true, liveness healthcheck will reset the master server if the the master server is not the master server cofigured in here
        resetMasterNodes: true
        #Declare the time when reset action can happen, only used if resetMasterNodes is true
        resetStart: 0 #hour 0-23 inclusive, optional
        resetEnd: 23 #hour 0-23 exclusive, optional

