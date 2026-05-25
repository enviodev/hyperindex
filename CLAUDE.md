# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

HyperIndex is a multichain blockchain indexing framework. The CLI (Rust) generates a ReScript runtime project from user config (`config.yaml` + `schema.graphql` + handlers). The runtime processes blockchain events via HyperSync or RPC and writes to PostgreSQL/ClickHouse, exposing a GraphQL API.

## Commands

Use `pnpm` over `npm`/`npx`.

### ReScript runtime (`packages/envio` or `scenarios/test_codegen`)
```bash
pnpm rescript          # compile ReScript
pnpm vitest run        # run all tests
pnpm vitest run test/specific_test.res.mjs   # single test file
```

### Rust CLI (`packages/cli`)
```bash
cargo clippy -- -D warnings        # lint
cargo test --no-default-features    # unit tests
cargo test --features integration_tests  # integration tests
cargo fmt -- --config format_strings=true  # format
```

### Scenario tests (e.g. `scenarios/test_codegen`)
```bash
pnpm exec envio codegen   # must run before tests
pnpm test                 # rescript && tsc --noEmit && vitest run
```

### E2E tests (`packages/e2e-tests`)
```bash
pnpm test:templates    # template generation tests
pnpm test:e2e          # full e2e with DB
pnpm lint              # tsc --noEmit
```

## Architecture

### Packages
- **`packages/cli`** — Rust NAPI addon. Parses config, runs codegen via Handlebars templates, produces the ReScript runtime project under `<user-project>/.envio/`.
- **`packages/envio`** — ReScript runtime library (npm package). Event sourcing, decoding, processing, DB writes.
- **`packages/e2e-tests`** — Template and end-to-end tests.
- **`packages/build-envio`** — Build script for the npm artifact.

### Config pipeline
`config.yaml` → `human_config.rs` → `system_config.rs` → internal JSON → `hbs_templating/codegen_templates.rs` → generated `Config.res`

### Event processing pipeline
1. **Sources** (`src/sources/`): `HyperSyncSource.res` or `RpcSource.res` fetch raw logs
2. **Decoding**: Native HyperSync client decoder (`HyperSyncClient.Decoder`) decodes ABI params from log data/topics
3. **Conversion**: `convertHyperSyncEventArgs` maps positional decoded arrays to named param objects; `componentsToRemapper` handles struct→object conversion
4. **Routing**: `EventRouter` matches logs to registered event configs by sighash + topic count + address
5. **Processing**: `EventProcessing.res` runs user handlers, serializes params via `paramsRawEventSchema` for raw_events table
6. **Storage**: `DbFunctions.res` writes entities to PostgreSQL

### Key modules
- **`Internal.res`** — Core types: `eventConfig`, `evmEventConfig`, `eventParams`, `item` (the processing queue item)
- **`EventConfigBuilder.res`** — Builds event configs from ABI params: decoder functions, schemas, topic filters
- **`ChainMap`** — Chain-keyed collections used throughout for multichain support
- **`EventRouter`** — Routes decoded logs to the correct event config
- **`Source.res`** — Common source interface implemented by HyperSync/RPC/Fuel/SVM sources

### Ecosystem abstraction
EVM, Fuel, and SVM share the same processing pipeline. Ecosystem-specific logic is isolated in source modules and config builders. The `ecosystem` field on config carries per-ecosystem helpers.

### Codegen vs runtime
Edit templates under `packages/cli/templates/` or runtime code in `packages/envio/src/`. Never edit generated output under `<project>/.envio/`.

## Navigation

- Rust CLI entry: `packages/cli/src/lib.rs`, commands: `commands.rs`
- Prefer reading `.res` modules directly; ignore compiled `.js`/`.mjs` artifacts

## Testing

- Always use single assert to check the whole value instead of multiple asserts for every field
- Prefer public module API for testing
- Verify: compile with `pnpm rescript`, then run `pnpm vitest run`
- Scenario tests require `pnpm exec envio codegen` before running
- Test files: `*_test.res` (ReScript) or `*.test.ts` (TypeScript), run via vitest

## Plan Mode

- Make the plan extremely concise. Sacrifice grammar for the sake of concision.
- At the end of each plan, give me a list of unresolved questions to answer, if any.
- Finish every plan by running tests.

## Comments

- Default to writing no comments. A comment earns its place only when it explains something the code itself cannot show.
- Write a comment when it captures: a non-obvious constraint, a subtle invariant, a workaround for a specific bug, or behavior that would surprise a reader.
- Don't write a comment that restates what the code already says — module purpose, what a function does, which callers use a value, history of a refactor, or pointers to where something is "now defined".
- Never narrate the refactor itself ("previously lived in X", "centralized here", "now imports from Y"). That belongs in the commit message, not the code.
- When refactoring, keep comments that still explain non-obvious behavior; drop or rewrite comments that described the old shape.

## ReScript

- When using `Utils.magic` for type casting, always add explicit type annotations: `value->(Utils.magic: inputType => outputType)`
- Always use ReScript 12 documentation. Never suggest ReasonML syntax.
- Never use `[| item |]` to create an array. Use `[ item ]` instead.
- Must always use `=` for setting value to a field. Use `:=` only for ref values created using `ref` function.
- Never use `%raw` to access object fields if you know the type.
- In tests, never log — use `Assert` module for all verifications.
- Use try/catch as expressions instead of refs for tracking success/failure.
