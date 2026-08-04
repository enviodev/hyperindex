---
name: indexer-local-parallel
description: >-
  Use when running two or more indexers locally at the same time (pnpm dev in
  multiple projects on one machine). Per-project ENVIO_PG_SCHEMA and
  ENVIO_INDEXER_PORT against the shared local Postgres, plus the Hasura
  metadata caveat and its dedicated-Hasura workaround.
metadata:
  managed-by: envio
---

# Running Multiple Indexers Locally in Parallel

The local CLI creates its Docker resources with fixed global names
(`envio-postgres`, `envio-hasura`, `envio-network`, `envio-postgres-data`), so
two projects on default settings collide: the second `pnpm dev` either fails on
the container-name conflict or attaches to the same database and schema, where
one project's migrations clobber the other's data. Tracked in
enviodev/hyperindex#1397.

## The working pattern: per-project schema + port

Give every concurrently-running project its own Postgres schema and indexer
port in the project's `.env`, so plain `pnpm dev` picks them up:

```bash
# .env of each additional indexer project
ENVIO_PG_SCHEMA=myproject   # unique per project, [a-z0-9_]
ENVIO_INDEXER_PORT=9899     # unique per project, default is 9898
```

All projects then share the one `envio-postgres` container, each project's data
lands in its own schema, and every indexer syncs at full speed. This pattern is
proven at scale: 20+ indexers side by side against a single local Postgres.
If you forget the vars, the CLI errors are friendly and name exactly these
variables, but setting them up front avoids the failed first run.

Tips:

- Derive schema and port deterministically from the project name in any
  scripting (for example, port = 9800 + a stable hash of the name) so re-runs
  and restarts always land on the same resources.
- Inspect any project's progress directly, regardless of Hasura state:

  ```bash
  docker exec envio-postgres psql -U postgres -d envio-dev \
    -c "select chain_id, num_events_processed from <schema>.chain_metadata;"
  ```

- Dropping a finished project's schema is safe cleanup and reclaims disk;
  never drop a schema an indexer is actively syncing into.

## Caveat: shared Hasura tracking is last-writer-wins

`ENVIO_PG_SCHEMA` isolates the data but NOT Hasura metadata. Each indexer's
"Tracking tables in Hasura" step replaces the tracked-table metadata rather
than merging it, so whichever project (re)started most recently is the only one
queryable on `:8080`. Earlier projects keep indexing fine (writes go straight
to Postgres), but their GraphQL surface silently disappears, and shared root
fields like `chain_metadata` resolve to the last writer's data.

If you only need one project's GraphQL API at a time, or you query Postgres
directly, this may be acceptable: restarting a project re-tracks its tables.

## Workaround: a dedicated Hasura per extra project

To give an additional project its own always-available GraphQL API, run a
second Hasura against the same Postgres with its own metadata database,
tracking only that project's schema:

```bash
docker exec envio-postgres psql -U postgres \
  -c "CREATE DATABASE hasura_meta_myproject;"

docker run -d --name myproject-hasura --network envio-network -p 8081:8080 \
  -e HASURA_GRAPHQL_METADATA_DATABASE_URL="postgres://postgres:testing@envio-postgres:5432/hasura_meta_myproject" \
  -e HASURA_GRAPHQL_ADMIN_SECRET=testing \
  -e HASURA_GRAPHQL_ENABLE_CONSOLE=true \
  -e HASURA_GRAPHQL_CORS_DOMAIN='*' \
  -e HASURA_GRAPHQL_STRINGIFY_NUMERIC_TYPES=true \
  hasura/graphql-engine:v2.43.0
```

Then add the source and track the schema's tables via the metadata API. Three
gotchas that cost real debugging time:

1. **Enum types**: entity enums live in the custom schema, and Hasura's
   generated SQL casts them unqualified, so filters fail with
   `type "mystatus" does not exist`. Fix: append
   `?options=-c%20search_path%3Dmyproject%2Cpublic` to the source's
   `database_url`.
2. **Root-field names**: tables in a non-public schema get schema-prefixed
   GraphQL fields by default. Pass `custom_root_fields` in `pg_track_table` to
   keep parity with the envio-managed Hasura's field names.
3. **Numeric serialization**: set `HASURA_GRAPHQL_STRINGIFY_NUMERIC_TYPES=true`
   to match the envio-managed Hasura (BigInt columns serialized as strings).
   Note it also stringifies Float columns, so client code should coerce.
