# Run this full scenario

Run from this directory:

```bash

envio codegen
docker compose up -d # NOTE: if you have some stale data, run "docker compose down -v" first.
PG_PORT=5433 pnpm start
```

To view the data in the database, run `./generated/register_tables_with_hasura.sh` and open http://localhost:8080/console.

Alternatively you can open the file `index.html` for a cleaner experience (no hasura stuff). Unfortunately, hasura currently isn't configured to make the data public.

## Build

```

pnpm run build

```

# Watch

```

pnpm run watch

```

```

```
