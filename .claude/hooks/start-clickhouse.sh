#!/bin/bash
# Start ClickHouse for the scenario test suite's ClickHouse leg.
# Configures: HTTP port 8123, user default, password testing
# (matches the CI service in build_and_verify.yml and packages/e2e-tests/src/config.ts)

set -e

PORT=8123
PASS="testing"
VERSION="26.2.15.4"
PREFIX="/opt/clickhouse"
BIN="$PREFIX/clickhouse-common-static-$VERSION/usr/bin/clickhouse"
DATA="/var/lib/clickhouse-test"
CONFIG="$DATA/config.xml"

if curl -sf --max-time 2 "http://127.0.0.1:$PORT/ping" >/dev/null 2>&1; then
  echo "ClickHouse already running on port $PORT"
  exit 0
fi

if [ ! -x "$BIN" ]; then
  mkdir -p "$PREFIX"
  curl -fsSL "https://packages.clickhouse.com/tgz/stable/clickhouse-common-static-$VERSION-amd64.tgz" \
    -o "$PREFIX/ch.tgz"
  tar -xzf "$PREFIX/ch.tgz" -C "$PREFIX"
  rm -f "$PREFIX/ch.tgz"
fi

mkdir -p "$DATA"

# The common-static tarball ships no config, so write a minimal one. Keeping it
# beside the data directory means a wiped $DATA rebuilds both together.
cat > "$CONFIG" <<XML
<clickhouse>
    <logger>
        <level>warning</level>
        <console>1</console>
    </logger>
    <http_port>$PORT</http_port>
    <listen_host>127.0.0.1</listen_host>
    <path>$DATA/data/</path>
    <tmp_path>$DATA/tmp/</tmp_path>
    <user_files_path>$DATA/user_files/</user_files_path>
    <user_directories>
        <users_xml>
            <path>$DATA/users.xml</path>
        </users_xml>
    </user_directories>
    <mark_cache_size>268435456</mark_cache_size>
</clickhouse>
XML

cat > "$DATA/users.xml" <<XML
<clickhouse>
    <profiles><default></default></profiles>
    <users>
        <default>
            <password>$PASS</password>
            <profile>default</profile>
            <quota>default</quota>
            <access_management>1</access_management>
            <networks><ip>::/0</ip></networks>
        </default>
    </users>
    <quotas><default></default></quotas>
</clickhouse>
XML

nohup "$BIN" server --config-file="$CONFIG" >"$DATA/server.log" 2>&1 &

for _ in $(seq 1 30); do
  if curl -sf --max-time 2 "http://127.0.0.1:$PORT/ping" >/dev/null 2>&1; then
    echo "ClickHouse $VERSION ready on port $PORT"
    exit 0
  fi
  sleep 1
done

echo "ERROR: ClickHouse failed to start on port $PORT"
tail -20 "$DATA/server.log" || true
exit 1
