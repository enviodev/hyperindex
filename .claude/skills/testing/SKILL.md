---
name: testing
description: >-
  Use when writing, running or debugging a test in `packages/envio-tests` or
  `scenarios/`: which test rung to pick, the command for one test, virtual
  time, reading a run's captured logs.
---

# Testing

Reproduce from outside in: real `config.yaml`, `schema.graphql` and handler source, never a call into an internal module. Pick the highest rung that reproduces. Run it and watch it fail before touching the source: a test that passes has reproduced nothing yet.

## Rungs

1. **User API** (default). `InternalTestIndexer.fromUserApi(~configYaml, ~schema, ~handlers, ~test)`: user YAML, schema, handler and test source, type-checked and executed with the real `createTestIndexer()`. No codegen, no database. Copy `packages/envio-tests/test/TokenIndexer_test.res`.
2. **Scenario**. `Scenario.make(~configYaml, ~schema, ~handlers)`, then `scenario->Scenario.it("name", async (~indexer, ~source) => ...)`: the real indexer loop and real storage over a `MockSource` per chain. For a bug in the loop itself: fetching, reorgs, batching, writes. Copy `packages/envio-tests/test/HandlerLogs_test.res`.
3. **End to end**. `scenarios/e2e_test` and `packages/e2e-tests`, for what the rungs above can't mock: Hasura, Docker, the CLI itself. CI runs them against real services.

## Commands

```bash
# from packages/envio-tests
pnpm rescript && pnpm vitest run -t "test name"
pnpm rescript && pnpm vitest run test/HandlerLogs_test.res.mjs
ENVIO_TEST_STORAGE=clickhouse pnpm vitest run -t "test name"   # or `both`; Postgres is the default
pnpm lint
```

```bash
# from the repo root
(cd scenarios/e2e_test && pnpm exec envio codegen && pnpm test)
(cd scenarios/test_codegen && pnpm exec envio codegen && pnpm test && pnpm exec rescript format src/Indexer.res)
pnpm test:cli
```

- `scenarios/test_codegen` type-checks the generated code. Its codegen rewrites the tracked `src/Indexer.res` unformatted, which is why the command formats it after.
- A Rust change needs no manual build: the `vitest` setup in `packages/envio-tests` and the `envio` bin each run `cargo build --lib` first, unless a prebuilt `envio-<platform>` package is installed, as it is in CI.
- `pnpm lint` takes about a second. The push check runs it, and CI runs it as the step "Lint test inputs" ahead of the tests.

## Virtual time

Scenarios run the indexer's timers on a clock only the test moves: nothing the indexer schedules fires until `await indexer.advanceTime(ms)`.

- Answer a chain's first height: `await Scenario.resolveInitialHeight(~source=source(1), ~head=300)`.
- Name each height call at the step that causes it: `await mock.expectNewHeightCalls(n)`, or `expectNewHeightCallsAtLeast(n)` where jitter decides the count. Once a test names one, an unnamed call fails the run.
- Wait for queries by naming them: `await mock.expectItemsQueries([...])`. Never `Utils.delay(0)` or a poll.
- A handler that takes time: `await indexer.delay(ms)` in the handler, `await indexer.advanceTime(ms)` in the test, then assert the exact duration.
- Off virtual time: `~virtualTime=false` on `Scenario.it` or `Scenario.make`, with a comment above saying why.
- A wait that really is real time (a database poll, events from the addon's threads): a `// Real time: <why>` comment above it.
- A failure prints the clock's pending timers, its timeline and how far to advance. `ENVIO_TEST_SEED=<seed>` replays a run's jitter.

## Logs

Logs never reach the test output; each run captures its own. `indexer.infoAndAboveLogs()` gives info and above as `{msg, params}`, `indexer.allLogsAsJson()` every line, trace included. A failing run's message ends with `Logs: <path>`, a `.test-logs/*.jsonl` file: read it only when the failure needs it.

## ReScript in tests

- ReScript 12 syntax and docs, never ReasonML.
- `try`/`catch` is an expression: use its value, not a ref set inside it.
