#  @Author: https://github.com/sarweshsuman
#  @Description:
#    Entrypoint script for deploying redis HA via Sentinel in a kubernetes cluster
#    This script expects following environment variables to be set,
#    1. SENTINEL: true if this is sentinel instance, else false.
#    2. MASTER: true if this is master instance, this is helpful when starting the cluster for the first time.
#    3. REDIS_HA_CLUSTER_SENTINEL_SERVICE_SERVICE_HOST: this is service name of sentinel, check the yaml.
#    4. REDIS_HA_CLUSTER_SENTINEL_SERVICE_SERVICE_PORT: this is service port of sentinel.
#    5. REDIS_HA_CLUSTER_STARTUP_REDIS_MASTER_SERVICE_SERVICE_HOST: this is master's service name, this is needed when sentinel starts for the first time.
#    6. REDIS_HA_CLUSTER_STARTUP_REDIS_MASTER_SERVICE_SERVICE_PORT: this is master's port, is needed when sentinel starts for the first time.


#  This method launches redis instance which assumes it self as master
function launchmaster() {
  echo "Starting Redis instance as Master.."

  echo "while true; do   sleep 2;   export master=\$(hostname -i);   echo \"Master IP is Me : \${master}\";   echo \"Setting STARTUP_MASTER_IP in redis\";   redis-cli -a ${REDIS_DEFAULT_PASSWORD} -h \${master} set STARTUP_MASTER_IP \${master};   if [ \$? == \"0\" ]; then     echo \"Successfully set STARTUP_MASTER_IP\";     break;   fi;   echo \"Connecting to master \${master} failed.  Waiting...\";   sleep 5; done" > insert_master_ip.sh

  bash insert_master_ip.sh &

  sed -i "s/REDIS_DEFAULT_PASSWORD/${REDIS_DEFAULT_PASSWORD}/" /redis-master/redis.conf
  redis-server /redis-master/redis.conf --protected-mode no

}

#  This method launches sentinels
function launchsentinel() {
  echo "Starting Sentinel.."
  sleep_for_rand_int=$(awk -v min=2 -v max=7 'BEGIN{srand(); print int(min+rand()*(max-min+1))}')
  sleep ${sleep_for_rand_int}

  while true; do
    echo "Trying to connect to Sentinel Service"
    master=$(redis-cli -h ${REDIS_HA_CLUSTER_SENTINEL_SERVICE_SERVICE_HOST} -p ${REDIS_HA_CLUSTER_SENTINEL_SERVICE_SERVICE_PORT} --csv SENTINEL get-master-addr-by-name mymaster | tr ',' ' ' | cut -d' ' -f1)
    if [[ -n ${master} ]]; then
      echo "Connected to Sentinel Service and retrieved Redis Master IP as ${master}"
      master="${master//\"}"
    else
      echo "Unable to connect to Sentinel Service, probably because I am first Sentinel to start. I will try to find STARTUP_MASTER_IP from the redis service"
      master=$(redis-cli -a ${REDIS_DEFAULT_PASSWORD} -h ${REDIS_HA_CLUSTER_STARTUP_REDIS_MASTER_SERVICE_SERVICE_HOST} -p ${REDIS_HA_CLUSTER_STARTUP_REDIS_MASTER_SERVICE_SERVICE_PORT} get STARTUP_MASTER_IP)
      if [[ -n ${master} ]]; then
        echo "Retrieved Redis Master IP as ${master}"
      else
        echo "Unable to retrieve Master IP from the redis service. Waiting..."
        sleep 10
        continue
      fi
    fi

    redis-cli -a ${REDIS_DEFAULT_PASSWORD} -h ${master} INFO
    if [[ "$?" == "0" ]]; then
      break
    fi
    echo "Connecting to master failed.  Waiting..."
    sleep 10
  done

  sentinel_conf=sentinel.conf

  echo "sentinel monitor mymaster ${master} 6379 2" > ${sentinel_conf}
  echo "sentinel down-after-milliseconds mymaster 5000" >> ${sentinel_conf}
  echo "sentinel failover-timeout mymaster 60000" >> ${sentinel_conf}
  echo "sentinel parallel-syncs mymaster 1" >> ${sentinel_conf}
  echo "bind 0.0.0.0" >> ${sentinel_conf}
  echo "sentinel auth-pass mymaster ${REDIS_DEFAULT_PASSWORD}" >> ${sentinel_conf}

  redis-sentinel ${sentinel_conf} --protected-mode no
}

#  This method launches slave instances
function launchslave() {
  echo "Starting Redis instance as Slave , Master IP $1"

  while true; do
    echo "Trying to retrieve the Master IP again, in case of failover master ip would have changed."
    master=$(redis-cli -h ${REDIS_HA_CLUSTER_SENTINEL_SERVICE_SERVICE_HOST} -p ${REDIS_HA_CLUSTER_SENTINEL_SERVICE_SERVICE_PORT} --csv SENTINEL get-master-addr-by-name mymaster | tr ',' ' ' | cut -d' ' -f1)
    if [[ -n ${master} ]]; then
      master="${master//\"}"
    else
      echo "Failed to find master."
      sleep 60
      continue
    fi
    redis-cli -a ${REDIS_DEFAULT_PASSWORD} -h ${master} INFO
    if [[ "$?" == "0" ]]; then
      break
    fi
    echo "Connecting to master failed.  Waiting..."
    sleep 10
  done

  sed -i "s/%master-ip%/${master}/" /redis-slave/redis.conf
  sed -i "s/%master-port%/6379/" /redis-slave/redis.conf
  sed -i "s/REDIS_DEFAULT_PASSWORD/${REDIS_DEFAULT_PASSWORD}/" /redis-slave/redis.conf
  redis-server /redis-slave/redis.conf --protected-mode no
}


#  This method launches either slave or master based on some parameters
function launchredis() {
  echo "Launching Redis instance"

  # Loop till I am able to launch slave or master
  while true; do
    # I will check if sentinel is up or not by connecting to it.
    echo "Trying to connect to sentinel, to retireve master's ip"
    master=$(redis-cli -h ${REDIS_HA_CLUSTER_SENTINEL_SERVICE_SERVICE_HOST} -p ${REDIS_HA_CLUSTER_SENTINEL_SERVICE_SERVICE_PORT} --csv SENTINEL get-master-addr-by-name mymaster | tr ',' ' ' | cut -d' ' -f1)

    # Is this instance marked as MASTER, it will matter only when the cluster is starting up for first time.
    if [[ "${MASTER}" == "true" ]]; then
      echo "MASTER is set to true"
      # If I am able get master ip, then i will connect to the master, else i will asume the role of master
      if [[ -n ${master} ]]; then
        echo "Connected to Sentinel, this means it is not first time start, hence will start as a slave"
        launchslave ${master}
        exit 0
      else
        launchmaster
        exit 0
      fi
    fi

    # If I am not master, then i am definitely slave.
    if [[ -n ${master} ]]; then
      echo "Connected to Sentinel and Retrieved Master IP ${master}"
      launchslave ${master}
      exit 0
    else
      echo "Connecting to sentinel failed, Waiting..."
      sleep 10
    fi
  done
}

# Using hardcoded password for demo purpose, this needs to be adjusted
# as per the environment where this is used.
export REDIS_DEFAULT_PASSWORD="rpasswd"

if [[ "${SENTINEL}" == "true" ]]; then
  launchsentinel
  exit 0
fi

launchredis
