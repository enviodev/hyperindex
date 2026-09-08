#!/usr/bin/env bash
# Applies sql/clickhouse.sql to the indexer's ClickHouse. Run it after the
# indexer has created the entity tables, and again after any `pnpm codegen`
# that changes them.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/sql/apply.py" "${SCRIPT_DIR}/sql/clickhouse.sql"
