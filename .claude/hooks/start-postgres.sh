#!/bin/bash
# Start PostgreSQL 16 for scenario tests.
# Configures: port 5433, user postgres, password testing, database envio-dev
# (matches CI services in build_and_verify.yml and devFallback in Env.res)

set -e

PORT=5433
DB="envio-dev"
USER="postgres"
PASS="testing"

# Already running? Nothing to do.
if pg_isready -h 127.0.0.1 -p "$PORT" >/dev/null 2>&1; then
  echo "PostgreSQL 16 already running on port $PORT"
  exit 0
fi

# Ensure port is set to 5433
sudo sed -i "s/^port = .*/port = $PORT/" /etc/postgresql/16/main/postgresql.conf 2>/dev/null

# Use trust auth for local dev (password still required by app via connection string)
sudo sed -i 's/^local\s\+all\s\+postgres\s\+peer$/local   all             postgres                                trust/' /etc/postgresql/16/main/pg_hba.conf 2>/dev/null
sudo sed -i 's/scram-sha-256/trust/g' /etc/postgresql/16/main/pg_hba.conf 2>/dev/null

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
