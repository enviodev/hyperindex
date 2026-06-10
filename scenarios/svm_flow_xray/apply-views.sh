#!/usr/bin/env bash
# =====================================================================
# apply-views.sh - apply Flow X-Ray custom SQL views + track in Hasura.
# =====================================================================
#
# RUN THIS *AFTER* the indexer has created the entity tables, i.e. after
# `pnpm dev` / `pnpm docker-up` + `pnpm start` (codegen recreates the
# entity tables on every run, so this must be re-applied each time).
#
# It (1) applies sql/views.sql to the indexer Postgres via psql, then
# (2) tells Hasura to track each view + grant the public role select, and
# (3) reloads metadata + refreshes the materialized views.
#
# Connection defaults match HyperIndex's `envio local docker up`
# (packages/cli/src/docker_env.rs and packages/envio/src/Env.res).
# Override any of them via the ENVIO_PG_* / HASURA_* env vars below.
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="${SCRIPT_DIR}/sql/views.sql"

# --- Postgres connection (HyperIndex docker defaults) ---
PGHOST="${ENVIO_PG_HOST:-localhost}"
PGPORT="${ENVIO_PG_PORT:-5433}"
PGUSER="${ENVIO_PG_USER:-postgres}"
PGPASSWORD="${ENVIO_PG_PASSWORD:-${ENVIO_POSTGRES_PASSWORD:-testing}}"
PGDATABASE="${ENVIO_PG_DATABASE:-envio-dev}"
PG_SCHEMA="${ENVIO_PG_SCHEMA:-${ENVIO_PG_PUBLIC_SCHEMA:-public}}"
export PGPASSWORD

# --- Hasura metadata API (HyperIndex docker defaults) ---
HASURA_PORT="${HASURA_EXTERNAL_PORT:-8080}"
HASURA_URL="${HASURA_GRAPHQL_ENDPOINT:-http://localhost:${HASURA_PORT}}"
# Strip a trailing /v1/metadata if the caller passed the full endpoint.
HASURA_URL="${HASURA_URL%/v1/metadata}"
HASURA_METADATA_URL="${HASURA_URL}/v1/metadata"
HASURA_ADMIN_SECRET="${HASURA_GRAPHQL_ADMIN_SECRET:-testing}"
HASURA_ROLE="${HASURA_GRAPHQL_ROLE:-admin}"

# Views to track. Plain views + materialized views are both pg-trackable.
VIEWS=(
  "v_protocol_edge"
  "v_tx_flow"
  "v_tx_value"
  "v_interesting_tx"
  "v_whale_loop"
  "mint_price"
  "mv_liq_cascade"
  "mv_drift_contagion"
)
MAT_VIEWS=(
  "mv_liq_cascade"
  "mv_drift_contagion"
)

echo "=========================================================="
echo "Flow X-Ray: applying custom SQL views"
echo "  Postgres : ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE} (schema ${PG_SCHEMA})"
echo "  Hasura   : ${HASURA_METADATA_URL}"
echo "  SQL file : ${SQL_FILE}"
echo "=========================================================="

if [[ ! -f "${SQL_FILE}" ]]; then
  echo "ERROR: ${SQL_FILE} not found." >&2
  exit 1
fi

# ---------------------------------------------------------------------
# 1. Apply the SQL.
# ---------------------------------------------------------------------
echo "[1/3] Applying sql/views.sql via psql ..."
psql \
  --host="${PGHOST}" \
  --port="${PGPORT}" \
  --username="${PGUSER}" \
  --dbname="${PGDATABASE}" \
  --set ON_ERROR_STOP=1 \
  --file="${SQL_FILE}"
echo "      SQL applied."

# ---------------------------------------------------------------------
# 2. Track each view in Hasura + grant public-role select.
#    Mirrors what HyperIndex does for entity tables (pg_track_table +
#    pg_create_select_permission for role "public", source "default").
# ---------------------------------------------------------------------
hasura_meta() {
  # $1 = JSON payload. Surfaces non-2xx (other than already-tracked /
  # already-exists, which are expected on re-runs).
  local payload="$1"
  local resp
  resp="$(curl -sS \
    -X POST "${HASURA_METADATA_URL}" \
    -H "Content-Type: application/json" \
    -H "X-Hasura-Role: ${HASURA_ROLE}" \
    -H "X-Hasura-Admin-Secret: ${HASURA_ADMIN_SECRET}" \
    -d "${payload}")"
  if echo "${resp}" | grep -qiE '"(already-tracked|already-exists)"'; then
    return 0
  fi
  if echo "${resp}" | grep -qi '"error"'; then
    echo "      Hasura warning: ${resp}" >&2
  fi
}

echo "[2/3] Tracking views in Hasura (source=default, schema=${PG_SCHEMA}) ..."
# Force a fresh source introspection so freshly-created views are visible.
hasura_meta "{\"type\":\"reload_metadata\",\"args\":{\"reload_sources\":[\"default\"]}}"

for view in "${VIEWS[@]}"; do
  echo "      - track ${PG_SCHEMA}.${view}"
  hasura_meta "$(cat <<JSON
{
  "type": "pg_track_table",
  "args": {
    "source": "default",
    "table": { "schema": "${PG_SCHEMA}", "name": "${view}" },
    "configuration": { "custom_name": "${view}" }
  }
}
JSON
)"
  echo "      - grant public select on ${view}"
  hasura_meta "$(cat <<JSON
{
  "type": "pg_create_select_permission",
  "args": {
    "source": "default",
    "table": { "schema": "${PG_SCHEMA}", "name": "${view}" },
    "role": "public",
    "permission": { "columns": "*", "filter": {}, "allow_aggregations": true }
  }
}
JSON
)"
done

echo "      Reloading Hasura metadata ..."
hasura_meta "{\"type\":\"reload_metadata\",\"args\":{\"reload_sources\":[\"default\"]}}"

# ---------------------------------------------------------------------
# 3. Refresh materialized views (they are empty until first refresh).
# ---------------------------------------------------------------------
echo "[3/3] Refreshing materialized views ..."
for mv in "${MAT_VIEWS[@]}"; do
  echo "      - REFRESH MATERIALIZED VIEW ${PG_SCHEMA}.${mv}"
  psql \
    --host="${PGHOST}" \
    --port="${PGPORT}" \
    --username="${PGUSER}" \
    --dbname="${PGDATABASE}" \
    --set ON_ERROR_STOP=1 \
    --command="REFRESH MATERIALIZED VIEW \"${PG_SCHEMA}\".\"${mv}\";"
done

echo "=========================================================="
echo "Done. Views applied, tracked in Hasura, and refreshed."
echo "Query them at ${HASURA_URL}/v1/graphql"
echo "Re-run this script after every \`pnpm start\` (codegen recreates"
echo "the entity tables, which drops dependent views)."
echo "=========================================================="
