#!/usr/bin/env bash
# Two replicas of one shard and the Keeper they share, for the live test of a
# resume on a replica that hasn't fetched what the other took. They answer on
# http://127.0.0.1:8124 and :8125, as default/testing.
#
# Usage: replicated-clickhouse.sh <clickhouse binary> <directory>
set -euo pipefail

binary=$1
root=$(mkdir -p "$2" && cd "$2" && pwd)

cat > "$root/users.xml" <<EOF
<clickhouse>
    <profiles><default/></profiles>
    <quotas><default/></quotas>
    <users>
        <default>
            <password>testing</password>
            <networks><ip>::/0</ip></networks>
            <profile>default</profile>
            <quota>default</quota>
            <access_management>1</access_management>
        </default>
    </users>
</clickhouse>
EOF

for replica in a b; do
  case $replica in
    a) http=8124 tcp=9101 interserver=9201 ;;
    b) http=8125 tcp=9102 interserver=9202 ;;
  esac
  dir=$root/$replica
  mkdir -p "$dir"/{data,tmp,user_files,keeper/log,keeper/snapshots}
  keeper=""
  if [ "$replica" = a ]; then
    keeper="<keeper_server>
        <tcp_port>9181</tcp_port>
        <server_id>1</server_id>
        <log_storage_path>$dir/keeper/log</log_storage_path>
        <snapshot_storage_path>$dir/keeper/snapshots</snapshot_storage_path>
        <raft_configuration>
            <server><id>1</id><hostname>127.0.0.1</hostname><port>9234</port></server>
        </raft_configuration>
    </keeper_server>"
  fi
  cat > "$dir/config.xml" <<EOF
<clickhouse>
    <logger><level>warning</level><log>$dir/server.log</log><errorlog>$dir/error.log</errorlog></logger>
    <http_port>$http</http_port>
    <tcp_port>$tcp</tcp_port>
    <interserver_http_port>$interserver</interserver_http_port>
    <interserver_http_host>127.0.0.1</interserver_http_host>
    <listen_host>127.0.0.1</listen_host>
    <path>$dir/data/</path>
    <tmp_path>$dir/tmp/</tmp_path>
    <user_files_path>$dir/user_files/</user_files_path>
    <user_directories><users_xml><path>$root/users.xml</path></users_xml></user_directories>
    <display_name>replica-$replica</display_name>
    <mark_cache_size>134217728</mark_cache_size>
    <max_server_memory_usage_to_ram_ratio>0.2</max_server_memory_usage_to_ram_ratio>
    <macros><cluster>envio</cluster><shard>01</shard><replica>$replica</replica></macros>
    $keeper
    <zookeeper><node><host>127.0.0.1</host><port>9181</port></node></zookeeper>
    <distributed_ddl><path>/clickhouse/task_queue/ddl</path></distributed_ddl>
    <remote_servers>
        <envio>
            <shard>
                <internal_replication>true</internal_replication>
                <replica><host>127.0.0.1</host><port>9101</port><user>default</user><password>testing</password></replica>
                <replica><host>127.0.0.1</host><port>9102</port><user>default</user><password>testing</password></replica>
            </shard>
        </envio>
    </remote_servers>
</clickhouse>
EOF
  "$binary" server --config-file="$dir/config.xml" > "$dir/stdout.log" 2>&1 &
done

# Answering isn't enough: replicated DDL also needs Keeper to have elected
# itself, which it does a moment after the servers come up.
for port in 8124 8125; do
  for _ in $(seq 60); do
    if curl -sf -u default:testing "http://127.0.0.1:$port/" \
      --data-binary "SELECT count() FROM system.zookeeper WHERE path = '/'" > /dev/null; then
      continue 2
    fi
    sleep 1
  done
  echo "ClickHouse replica on port $port didn't come up:" >&2
  cat "$root"/*/error.log >&2 || true
  exit 1
done
