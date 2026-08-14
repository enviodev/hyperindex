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
- `rawRequest.ts` — `node:http` client used by transport probes, where
  `fetch` cannot be used because it negotiates and decodes `content-encoding`
  behind the caller's back.

## Transport probes and known gaps

Most cases are a POST of `{query, variables}` compared on the response body
alone. A case with a `transport` block instead controls the HTTP envelope —
method, path, request headers, raw body — and its snapshot additionally
records the response's `contentEncoding` and whichever response headers the
case lists in `compareHeaders`. `corpus/18-transport.ts` uses this to cover
the layer the body corpus is blind to: gzip, batched (JSON array) requests,
plain GET, and `x-request-id`.

Two annotations control how a case is judged:

- **`knownGap: "..."`** — serve is known not to match here yet. The case is
  still recorded from Hasura (the snapshot *is* the spec for the eventual
  implementation), a mismatch is reported as a known gap rather than a
  failure, and a case that starts *matching* fails loudly so the annotation
  gets removed with the fix. This is how a gap stays visible and tracked
  without a permanently red required CI job.
- **`recordOnly: true`** — record Hasura's answer, assert nothing about
  serve. For endpoints where matching Hasura is not the goal (serve should
  expose Prometheus metrics whether or not the Hasura edition under test
  does) but where the recorded answer still settles what Hasura actually did.

Closing a gap is therefore: implement it, drop the `knownGap` line, and both
`diffServe.ts` and the live suite flip from "known gap" to a hard assertion.

### What the recorded transport oracle says

Several of these behaviors are not what you would guess, and the snapshots —
not intuition — are the spec:

- **gzip is narrower than a stock compression middleware.** gzip is the only
  encoding Hasura implements; a missing `Accept-Encoding` *or* a bare `*` is
  treated as identity-only rather than permission to compress; and when both
  identity and gzip are acceptable, bodies under 700 bytes are left
  uncompressed. Only an explicit `identity;q=0` forces gzip regardless of
  size. No `Vary` header is sent at all.
- **Error responses get neither compression nor `x-request-id`.** Both are set
  in `logSuccessAndResp`; the error path (`logErrorAndResp`) sets only
  content-length and the JSON content type. So an error carries no request id
  even when the client supplied one — serve has to reproduce that asymmetry,
  not just start emitting the header everywhere.
- **Hasura does not execute query-over-GET.** `GET /v1/graphql` is wired to
  the Automatic Persisted Queries handler, which in the OSS build is
  `throw400 NotSupported "PersistedQueryNotSupported"`, turned into HTTP 200
  by the route's `allMod200`. The query string is never read, so every GET
  answers identically. The parity target is that fixed error body, not a GET
  execution path.
- **A malformed batch element is reported positionally.** A batch that fails
  to parse answers with a single error object (not an array) whose path is
  indexed to the offending element — `$[0]`, where serve reports `$`.
- **Prometheus metrics are not in CE.** `/v1/metrics` 404s on
  `hasura/graphql-engine:v2.43.0` (`server_type: "ce"`); it is an EE feature.
  Serve's metrics endpoint is therefore a requirement in its own right, with
  no CE oracle to match — hence `recordOnly` on that probe.

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

Bring up the same Hasura CI runs against, pointed at the local Postgres
(host networking, so `localhost:5433` resolves from inside the container):

```sh
docker run -d --name hasura-diff --network host \
  -e HASURA_GRAPHQL_DATABASE_URL='postgres://postgres:testing@localhost:5433/envio-dev' \
  -e HASURA_GRAPHQL_ADMIN_SECRET=testing \
  -e HASURA_GRAPHQL_UNAUTHORIZED_ROLE=public \
  -e HASURA_GRAPHQL_STRINGIFY_NUMERIC_TYPES=true \
  -e PORT=8080 hasura/graphql-engine:v2.43.0
```

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
usage to `fixtures/differential/hasura-baseline.json` (git-ignored and
machine-specific — record it once locally, and re-run after a real
perf-relevant Postgres/dataset change, not after every Rust edit); the
default mode benchmarks only `envio serve` against that stored baseline,
so Hasura/Docker can stay stopped while iterating on Rust.
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

## Needs a live-Hasura re-record

Fixture/schema changes invalidate ALL recorded snapshots (including
introspection), so the items below batch into one re-record session against
live Hasura v2.43 (`pnpm record:differential` after the fixture edits):

- **`column_name_format: snake_case` fixture coverage** — serve supports the
  snake_case column-name mode but the fixture only exercises the default
  camelCase naming; add a snake_case-configured schema variant and corpus
  cases so naming-mode parity is snapshot-verified.
- **`envio_effect_*` table in the fixture** — effect-cache tables get a
  public/admin visibility split distinct from entity tables; add one to
  `schema.sql` and record corpus cases for both roles to pin that split.
- **Byte-level (non-JSON-normalized) snapshot recording** — snapshots are
  stored as re-serialized parsed JSON, which hides float-formatting
  differences (e.g. `1.0` vs `1`); record raw response bytes alongside so
  float-formatting parity is verifiable.
- **Auth-matrix corpus cases** — only public/admin/admin-wrong are covered;
  record combinations of `X-Hasura-Role` with and without a valid admin
  secret (and unknown roles) to pin the full role-resolution matrix.

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
