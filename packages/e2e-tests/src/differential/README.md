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

**Fast loop (Rust iteration — no Hasura/Docker needed):** the oracle
snapshots under `fixtures/differential/snapshots/` are the correctness
ground truth. Start `envio serve` against the small fixture dataset
(`schema.sql` + `seed.sql`, no `bench-seed.sql`) and diff:

```sh
cd scenarios/test_codegen && pnpm exec envio serve --port 8081 &
cd packages/e2e-tests && pnpm exec tsx src/differential/diffServe.ts
```

This runs the ~590 default-phase cases concurrently in a few seconds
against the already-recorded snapshots — nothing needs live Hasura. Use
`--phase limited` (with serve restarted under
`ENVIO_HASURA_RESPONSE_LIMIT=5 ENVIO_HASURA_PUBLIC_AGGREGATE='["User","Token","SimpleEntity","raw_events","_meta"]'`)
for the limited-phase cases, and `--filter <substr>` / `--verbose N` to
narrow down a failure.

**Full suite (needs Postgres 5433 + Hasura 8080 live — CI runs this):**

```sh
pnpm --filter e2e-tests record:differential   # refresh Hasura oracle snapshots
pnpm --filter e2e-tests test:differential     # diff Hasura vs envio serve, both engines live
```

`test:differential` spawns `envio serve` itself and drives every HTTP case
plus the WebSocket subscription scenarios (`subscriptions.test.ts`)
against a live Hasura container — the authoritative check before landing
a change, but slower (~5 min) since every case is a live round trip to
both engines. Prefer `diffServe.ts` for iteration; run this before a PR.

### Benchmarking

Also needs Hasura only once — see `bench.ts`'s module doc comment. In
short: `--record-baseline` captures Hasura's per-case timing + resource
usage to `fixtures/differential/hasura-baseline.json` (committed; re-run
after a real perf-relevant Postgres/dataset change, not after every Rust
edit); the default mode benchmarks only `envio serve` against that stored
baseline, so Hasura/Docker can stay stopped while iterating on Rust.
`bench.ts` measures timing only — always confirm correctness with
`diffServe.ts` on the small dataset separately.

### Soak / load testing

`bench.ts` is single-connection (concurrency 1) latency only. `soakLoad.ts`
fires a mixed sample of the `bench: true` corpus at N concurrent workers
against a running `envio serve` for an extended duration, and checks the
things that only show up under sustained concurrent load: RSS growth
(leak), fd-count growth (leak), p99 latency drift over time, and zero 5xx
responses. Needs `envio serve` already running (or pass `--spawn`) — no
Hasura needed.

```sh
cd scenarios/test_codegen && pnpm exec envio serve --port 8081 &
cd packages/e2e-tests
pnpm soak:differential -- --duration 60s --concurrency 32        # quick local iteration
pnpm soak:differential -- --duration 2h --concurrency 48 --spawn # real acceptance soak
```

Exits non-zero (and prints why) on any 5xx, an RSS or fd-count growth
trend past a configurable threshold (excluding an initial warmup slice),
or late-run p99 more than `--p99-drift-multiplier` (default 2x) worse than
an early stabilized window. See the flag list in `soakLoad.ts`'s module
doc comment for the full set of thresholds/knobs.

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
