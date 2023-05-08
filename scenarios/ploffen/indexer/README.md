# Ploffen Example

Quickstart: run from this directory:

```bash
docker compose -f ../../../docker-compose.yaml up -d # NOTE: if you have some stale data, run "docker compose down -v" first. Run this in the scenarios/ploffen/indexer
pnpm codegen
pnpm deploy-default
pnpm start
```

To view the data in the database, run `./generated/register_tables_with_hasura.sh` and open http://localhost:8080/console.

Alternatively you can open the file `index.html` for a cleaner experience (no hasura stuff). Unfortunately, hasura currently isn't configured to make the data public.

## Other Dev commands:

Build:

```
pnpm run build

```

Watch

```

pnpm run watch

```
