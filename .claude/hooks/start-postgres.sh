#!/bin/bash
# Start PostgreSQL 16 for scenario tests.
# Configures: port 5433, user postgres, password testing, database envio-dev
# (matches CI services in build_and_verify.yml and devFallback in Env.res)

set -e

PORT=5433
DB="envio-dev"
USER="postgres"
PASS="testing"

CONF=/etc/postgresql/16/main/postgresql.conf
CERTS=/var/lib/postgresql/tls

# Serves TLS with a certificate signed by a CA this machine trusts, so the live
# tests can tell a verified connection from an unverified one. The same setup
# runs in CI, against a container instead of this cluster.
ensure_tls() {
  # Every part has to be in place, not just the line naming the certificate: a
  # cluster stopped half way through this would otherwise start without TLS.
  if grep -q '^ssl = on' "$CONF" &&
    grep -q "^ssl_cert_file = '$CERTS/server.crt'" "$CONF" &&
    grep -q "^ssl_key_file = '$CERTS/server.key'" "$CONF" &&
    sudo test -s "$CERTS/server.crt" &&
    sudo test -s "$CERTS/server.key"; then
    return
  fi
  "$(dirname "$0")/../../scripts/pg-tls.sh" "$CERTS" postgres:postgres >/dev/null
  sudo sed -i "s|^#*ssl = .*|ssl = on|; \
    s|^#*ssl_cert_file = .*|ssl_cert_file = '$CERTS/server.crt'|; \
    s|^#*ssl_key_file = .*|ssl_key_file = '$CERTS/server.key'|" "$CONF"
  if pg_isready -h 127.0.0.1 -p "$PORT" >/dev/null 2>&1; then
    sudo pg_ctlcluster 16 main reload
  fi
}

# Already running? Only the certificate may still be missing.
if pg_isready -h 127.0.0.1 -p "$PORT" >/dev/null 2>&1; then
  ensure_tls
  echo "PostgreSQL 16 already running on port $PORT"
  exit 0
fi

# Ensure port is set to 5433
sudo sed -i "s/^port = .*/port = $PORT/" /etc/postgresql/16/main/postgresql.conf 2>/dev/null

# Use trust auth for local dev (password still required by app via connection string)
sudo sed -i 's/^local\s\+all\s\+postgres\s\+peer$/local   all             postgres                                trust/' /etc/postgresql/16/main/pg_hba.conf 2>/dev/null
sudo sed -i 's/scram-sha-256/trust/g' /etc/postgresql/16/main/pg_hba.conf 2>/dev/null

ensure_tls

# Start the cluster
sudo pg_ctlcluster 16 main start 2>/dev/null

# Wait up to 15 seconds
for i in $(seq 1 15); do
  if pg_isready -h 127.0.0.1 -p "$PORT" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! pg_isready -h 127.0.0.1 -p "$PORT" >/dev/null 2>&1; then
  echo "ERROR: PostgreSQL 16 failed to start on port $PORT"
  exit 1
fi

# Set password and create database (idempotent)
psql -U "$USER" -h 127.0.0.1 -p "$PORT" -c "ALTER USER $USER PASSWORD '$PASS';" 2>/dev/null
psql -U "$USER" -h 127.0.0.1 -p "$PORT" -tc "SELECT 1 FROM pg_database WHERE datname = '$DB'" | grep -q 1 \
  || psql -U "$USER" -h 127.0.0.1 -p "$PORT" -c "CREATE DATABASE \"$DB\";" 2>/dev/null

echo "PostgreSQL 16 ready on port $PORT (database: $DB)"
