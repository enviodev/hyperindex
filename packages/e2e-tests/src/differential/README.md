# Differential GraphQL suite

Verifies that `envio serve` (the Rust GraphQL server) matches real Hasura
one-to-one, by running every corpus case against both engines and requiring
identical JSON responses — data, errors, and serialization alike.

## Layout

- `corpus/` — the query corpus, grouped by category. Each case runs as a
  given role (`public` = no auth headers, `admin` = admin secret) in one or
  more phases (`default` = production defaults; `limited` = response limit 5
  plus aggregates enabled for a few tables).
- `fixtureModel.ts` — the tracked tables and relationships of the fixture,
  mirroring exactly what `Hasura.res` `trackDatabase` derives from
  `scenarios/test_codegen/schema.graphql`.
- `hasuraSetup.ts` — replays the same metadata API calls the indexer makes
  at init (clear → reload → pg_track_tables → select permissions →
  relationships), parameterized by phase.
- `../../fixtures/differential/schema.sql` — DDL dump of the schema
  `envio local db-migrate setup` creates for scenarios/test_codegen.
- `../../fixtures/differential/seed.sql` — deterministic rows exercising
  serialization edge cases.
- `../../fixtures/differential/snapshots/` — recorded Hasura responses; the
  ground-truth oracle, regenerated with `pnpm record:differential`.

## Running

Requires the same services as the other e2e tests: Postgres on 5433 and
Hasura on 8080 (`envio local docker up` inside any scenario, or the CI
service containers).

```sh
pnpm --filter e2e-tests record:differential   # refresh Hasura oracle snapshots
pnpm --filter e2e-tests test:differential     # diff Hasura vs envio serve
```

The differential test spawns `envio serve` (from packages/envio, dev build)
against scenarios/test_codegen on port 8081.

## Regenerating the fixture schema

When the generated DDL changes (packages/envio/src/db/*), re-run:

```sh
cd scenarios/test_codegen && pnpm db-setup
PGPASSWORD=testing pg_dump -h localhost -p 5433 -U postgres -d envio-dev \
  --schema-only --schema=public --no-owner --no-privileges > /tmp/dump.sql
```

then clean it into `fixtures/differential/schema.sql` (drop psql
`\restrict` directives, `SET` statements, and the `CREATE SCHEMA public`
line — keep the header comment and the DROP/CREATE SCHEMA prelude).
