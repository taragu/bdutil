# Copyright 2014 Google Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS-IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o nounset
set -o errexit

install_application 'python-numpy' 'numpy'

SCALA_TARBALL=${SCALA_TARBALL_URI##*/}
gsutil cp ${SCALA_TARBALL_URI} /home/hadoop/${SCALA_TARBALL}
tar -C /home/hadoop -xzvf /home/hadoop/${SCALA_TARBALL}
mv /home/hadoop/scala*/ ${SCALA_INSTALL_DIR}

# Figure out which tarball to use based on which Hadoop version is being used.
set +o nounset
HADOOP_BIN="sudo -u hadoop ${HADOOP_INSTALL_DIR}/bin/hadoop"
HADOOP_VERSION=$(${HADOOP_BIN} version | tr -cd [:digit:] | head -c1)
set -o nounset
if [[ "${HADOOP_VERSION}" == '2' ]]; then
  SPARK_TARBALL_URI=${SPARK_HADOOP2_TARBALL_URI}
else
  SPARK_TARBALL_URI=${SPARK_HADOOP1_TARBALL_URI}
fi

SPARK_TARBALL=${SPARK_TARBALL_URI##*/}
SPARK_MAJOR_VERSION=$(sed 's/spark-\([0-9]*\).*/\1/' <<<${SPARK_TARBALL})
gsutil cp ${SPARK_TARBALL_URI} /home/hadoop/${SPARK_TARBALL}
tar -C /home/hadoop -xzvf /home/hadoop/${SPARK_TARBALL}
mv /home/hadoop/spark*/ ${SPARK_INSTALL_DIR}

# List all workers for master to ssh into when using start-all.sh.
echo ${WORKERS[@]} | tr ' ' '\n' > ${SPARK_INSTALL_DIR}/conf/slaves

# Find the Hadoop lib dir so that we can add its gcs-connector into the
# Spark classpath.
set +o nounset
if [[ -r "${HADOOP_INSTALL_DIR}/libexec/hadoop-config.sh" ]]; then
  . "${HADOOP_INSTALL_DIR}/libexec/hadoop-config.sh"
fi
if [[ -n "${HADOOP_COMMON_LIB_JARS_DIR}" ]] && \
    [[ -n "${HADOOP_PREFIX}" ]]; then
  LIB_JARS_DIR="${HADOOP_PREFIX}/${HADOOP_COMMON_LIB_JARS_DIR}"
else
  LIB_JARS_DIR="${HADOOP_INSTALL_DIR}/lib"
fi
set -o nounset

GCS_JARNAME=$(grep -o '[^/]*\.jar' <<< ${GCS_CONNECTOR_JAR})
LOCAL_GCS_JAR="${LIB_JARS_DIR}/${GCS_JARNAME}"

# Symlink hadoop's core-site.xml into spark's conf directory.
ln -s ${HADOOP_CONF_DIR}/core-site.xml ${SPARK_INSTALL_DIR}/conf/core-site.xml

# Create directories on the mounted local directory which may point to an
# attached PD for Spark to use for scratch, logs, etc.
SPARK_TMPDIR='/hadoop/spark/tmp'
SPARK_WORKDIR='/hadoop/spark/work'
SPARK_LOG_DIR='/hadoop/spark/logs'
mkdir -p ${SPARK_TMPDIR} ${SPARK_WORKDIR} ${SPARK_LOG_DIR}
chgrp hadoop -R /hadoop/spark
chmod 777 -R /hadoop/spark

# Calculate the memory allocations, MB, using 'free -m'. Floor to nearest MB.
TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
SPARK_WORKER_MEMORY=$(python -c \
    "print int(${TOTAL_MEM} * ${SPARK_WORKER_MEMORY_FRACTION})")
SPARK_DAEMON_MEMORY=$(python -c \
    "print int(${TOTAL_MEM} * ${SPARK_DAEMON_MEMORY_FRACTION})")
SPARK_EXECUTOR_MEMORY=$(python -c \
    "print int(${TOTAL_MEM} * ${SPARK_EXECUTOR_MEMORY_FRACTION})")

# Give "client" processes 1/4 of available memory; since this piece doesn't
# by default run in a strict container, we're allowing it to be a bit
# oversubscribed. This matches our HADOOP_CLIENT_OPTS setting for now.
SPARK_DRIVER_MEM_MB=$(python -c "print int(${TOTAL_MEM} / 4)")
SPARK_DRIVER_MAX_RESULT_MB=$(python -c "print int(${SPARK_DRIVER_MEM_MB} / 2)")

# If YARN is setup. Shrink memory to fit on NodeManagers.
if (( ${HADOOP_VERSION} > 1 )); then
  set +o nounset
  YARN_MEMORY_ENV=$(find /tmp/mrv2_*_env.sh | head -1)
  if [[ -r "${YARN_MEMORY_ENV}" ]]; then
    source "${YARN_MEMORY_ENV}"
  fi
  if [[ -n "${NODEMANAGER_MEM_MB}" ]]; then
    SPARK_EXECUTOR_MEMORY=$(python -c "print int(min( \
        ${SPARK_EXECUTOR_MEMORY}, ${NODEMANAGER_MEM_MB}))")
  fi
  set -o nounset
  # Make room for spark.yarn.executor.memoryOverhead roughly according to
  # http://spark.apache.org/docs/1.2.0/configuration.html.
  SPARK_YARN_EXECUTOR_MEMORY_OVERHEAD=$(python -c "print int(max( \
      ${SPARK_EXECUTOR_MEMORY} * 0.07 / 1.07, 384))")
  SPARK_EXECUTOR_MEMORY=$(( ${SPARK_EXECUTOR_MEMORY} - \
      ${SPARK_YARN_EXECUTOR_MEMORY_OVERHEAD} ))
else
  # Use simple default. It won't be used.
  SPARK_YARN_EXECUTOR_MEMORY_OVERHEAD=384
fi

# Determine Spark master using appropriate mode
if [[ ${SPARK_MODE} == 'standalone' ]]; then
  SPARK_MASTER="spark://${MASTER_HOSTNAME}:7077"
elif [[ ${SPARK_MODE} =~ ^(default|yarn-(client|cluster))$ ]]; then
  SPARK_MASTER="${SPARK_MODE}"
else
  echo "Invalid mode: '${SPARK_MODE}'. Preserving default behavior." >&2
  SPARK_MASTER='default'
fi

# Help spark find scala and the GCS connector.
cat << EOF >> ${SPARK_INSTALL_DIR}/conf/spark-env.sh
export SCALA_HOME=${SCALA_INSTALL_DIR}
export SPARK_WORKER_MEMORY=${SPARK_WORKER_MEMORY}m
export SPARK_MASTER_IP=${MASTER_HOSTNAME}
export SPARK_DAEMON_MEMORY=${SPARK_DAEMON_MEMORY}m
export SPARK_WORKER_DIR=${SPARK_WORKDIR}
export SPARK_LOCAL_DIRS=${SPARK_TMPDIR}
export SPARK_LOG_DIR=${SPARK_LOG_DIR}
export SPARK_CLASSPATH=\$SPARK_CLASSPATH:${LOCAL_GCS_JAR}
EOF

# For Spark 0.9.1 and older, Spark properties must be passed in programmatically
# or as system properties; newer versions introduce spark-defaults.conf. This
# usage of SPARK_JAVA_OPTS is deprecated for newer versions.
if [[ "${SPARK_MAJOR_VERSION}" == '0' ]]; then
cat << EOF >> ${SPARK_INSTALL_DIR}/conf/spark-env.sh
# Append to front so that user-specified SPARK_JAVA_OPTS at runtime will win.
export SPARK_JAVA_OPTS="-Dspark.executor.memory=\
${SPARK_EXECUTOR_MEMORY}m \${SPARK_JAVA_OPTS}"
export SPARK_JAVA_OPTS="-Dspark.local.dir=${SPARK_TMPDIR} \${SPARK_JAVA_OPTS}"

# Will be ingored if not running on YARN
export SPARK_JAVA_OPTS="-Dspark.yarn.executor.memoryOverhead=\
${SPARK_YARN_EXECUTOR_MEMORY_OVERHEAD} \${SPARK_JAVA_OPTS}"
EOF
fi

if [[ "${SPARK_MASTER}" != 'default' ]]; then
  echo "export MASTER=${SPARK_MASTER}" >> ${SPARK_INSTALL_DIR}/conf/spark-env.sh
  echo "spark.master ${SPARK_MASTER}" >> ${SPARK_INSTALL_DIR}/conf/spark-defaults.conf
fi

SPARK_EVENTLOG_DIR="gs://${CONFIGBUCKET}/spark-eventlog-base/${MASTER_HOSTNAME}"
if [[ "$(hostname -s)" == "${MASTER_HOSTNAME}" ]]; then
  source hadoop_helpers.sh
  HDFS_SUPERUSER=$(get_hdfs_superuser)
  DFS_CMD="sudo -i -u ${HDFS_SUPERUSER} hadoop fs"
  if ! ${DFS_CMD} -stat ${SPARK_EVENTLOG_DIR}; then
    if (( ${HADOOP_VERSION} > 1 )); then
      ${DFS_CMD} -mkdir -p ${SPARK_EVENTLOG_DIR}
    else
      ${DFS_CMD} -mkdir ${SPARK_EVENTLOG_DIR}
    fi
  fi
fi

# Misc Spark Properties that will be loaded by spark-submit.
# TODO(user): Instead of single extraClassPath, use a lib directory.
cat << EOF >> ${SPARK_INSTALL_DIR}/conf/spark-defaults.conf
spark.eventLog.enabled true
spark.eventLog.dir ${SPARK_EVENTLOG_DIR}

spark.executor.memory ${SPARK_EXECUTOR_MEMORY}m
spark.yarn.executor.memoryOverhead ${SPARK_YARN_EXECUTOR_MEMORY_OVERHEAD}

spark.driver.memory ${SPARK_DRIVER_MEM_MB}m
spark.driver.maxResultSize ${SPARK_DRIVER_MAX_RESULT_MB}m
spark.akka.frameSize 512
EOF

# Add the spark 'bin' path to the .bashrc so that it's easy to call 'spark'
# during interactive ssh session.
add_to_path_at_login "${SPARK_INSTALL_DIR}/bin"

# Assign ownership of everything to the 'hadoop' user.
chown -R hadoop:hadoop /home/hadoop/
