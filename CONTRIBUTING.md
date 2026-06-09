# Contributing to Envio

By submitting a Pull Request or making any contribution to this project, you automatically agree to and accept all terms outlined in our [Contributor License Agreement](./licenses/CLA.md). This includes all future contributions you may make to the project.

## Table of Contents

- [Installation](#installation)
- [Project Structure Overview](#project-structure-overview)
- [Indexer Runtime Architecture](#indexer-runtime-architecture)
- [Architecture Goal: Ports & Adapters (WIP)](#architecture-goal-ports--adapters-wip)
- [Update CLI Generated Docs](#update-cli-generated-docs)
- [Create templates](#create-templates)
- [Configure the files according to your project](#configure-the-files-according-to-your-project)
- [Generate code according to configuration](#generate-code-according-to-configuration)
- [Run the indexer](#run-the-indexer)
- [View the database](#view-the-database)

## Installation

Install prerequisite tools:

1. Node.js v22+ (v24 recommended) https://nodejs.org/en
   (Recommended to use a node manager like fnm or nvm)
2. pnpm

   ```sh
   npm install --global pnpm
   ```

3. Cargo https://doc.rust-lang.org/cargo/getting-started/installation.html

   ```sh
   curl https://sh.rustup.rs -sSf | sh
   ```

4. Docker Desktop https://www.docker.com/products/docker-desktop/

## Install `envio` Dev Version

> If you want to test the latest changes in the `envio` CLI

```sh
cargo install --path packages/cli --locked --debug
```

Command to see available CLI commands

```sh
envio --help
```

Alternatively you can add an alias in your shell config. This will allow you to test Envio locally without manual recompiling.

Go to your shell config file and add the following line:

```sh
alias lenvio="node <absolute repository path>/hyperindex/packages/envio/bin.mjs"
```

> `lenvio` is like `local envio` 😁

## Project Structure Overview

Envio is split into a Rust CLI, a shared runtime library (`packages/envio`),
and a thin per-project codegen output (`<project>/.envio/types.d.ts` plus the
committed `envio-env.d.ts` glue file at the project root).

Top-level folders:

- `packages/cli` – Rust source of the Envio CLI (`Cargo.toml` lives here).
  - `src/commands.rs` – dispatches sub-commands using Clap.
  - `src/executor/` – implementation details for each command.
  - `src/config_parsing/` – configuration loading pipeline:
    - `human_config.rs` → reads user `config.yaml`.
    - `system_config.rs` → converts user config into the internal representation.
  - `src/hbs_templating/codegen_templates.rs` – emits `<project>/.envio/types.d.ts`,
    `<project>/envio-env.d.ts`, and (for ReScript projects) `<project>/src/Indexer.res`.
  - `templates/` – code scaffold used during `envio init` / contract import
    (`dynamic/` for Handlebars, `static/` for raw files).

Main CLI commands:

1. `init` – interactive project scaffolding (`src/executor/init.rs`, `src/cli_args/interactive_init/`).
2. `codegen` – parses config and writes `<project>/.envio/types.d.ts` (augments
   the `envio` module with project-bound types), `<project>/envio-env.d.ts`
   (committed reference glue), and `src/Indexer.res` for ReScript projects.
3. `start` – runs `codegen` to refresh the on-disk types and then launches the indexer runtime.
4. `dev` – same codegen-then-launch flow as `start`, plus brings up Docker (Postgres, Hasura, ClickHouse when configured) and the local development services.

Codegen output layout:

1. Shared library: `packages/envio` (ReScript/TypeScript). Use `pnpm rescript -w`
   for live recompilation; no `pnpm codegen` needed for library edits.
2. Per-project codegen output: `<project>/.envio/types.d.ts` (git-ignored,
   regenerated every run) plus `<project>/envio-env.d.ts` (committed, stable).
3. Scenario & regression tests: `scenarios/` (e.g. `scenarios/test_codegen`).
   Run `pnpm codegen` then `pnpm test`. (You don't need to run `pnpm codegen`
   when changing library code.)

Navigation cheat-sheet (useful for code search / AI):

- CLI entry point: `packages/cli/src/lib.rs`
- Command definitions: `packages/cli/src/commands.rs`
- Arg parsing: `packages/cli/src/cli_args/`
- EVM helpers: `packages/cli/src/evm/`
- Fuel helpers: `packages/cli/src/fuel/`

## Indexer Runtime Architecture

All runtime code lives in the reusable library at `packages/envio`. User
projects pull in project-specific types via the augmented `envio` module
(`<project>/.envio/types.d.ts` + `<project>/envio-env.d.ts`).

Entry point:

- `Bin.res` (in `packages/envio`) – launched by `envio` (the `bin.mjs` CLI). Responsibilities:
  - Calls the Rust CLI via NAPI (`Core.runCli`) and decodes the single tagged `Command` it returns (`start` / `migrate` / `drop-schema`, or `null` for Rust-only work like `codegen`).
  - For `start`: primes the config JSON (`Config.prime`), sets `cwd` + env vars, then calls `Main.start(~migrate?)`.
  - For `migrate` / `drop-schema`: primes config and calls `Main.migrate` / `Main.dropSchema`.
- `Main.start` (in `packages/envio`) is the indexer entry proper. Responsibilities:
  - Parses CLI flags (`--tui-off`, etc.).
  - Loads runtime configuration (`Config.res`).
  - Starts an Express server that serves `/metrics`, `/health`, and the Development Console endpoints.
  - Initializes the Persistence layer (Postgres + Hasura) — a single `init()` call that also handles `~reset` + `upsertPersistedState` when `~migrate` is provided.
  - Loads user handler modules via `HandlerLoader.registerAllHandlers`.
  - Loads initial state (to resume from a previous run).
  - Spawns the `GlobalStateManager.res` which orchestrates fetch & process loops.

Configuration layer:

- `Config.res` – strongly typed runtime config. Parsed from the JSON the Rust CLI embeds in the `Command` payload (primed via `Config.prime` in `Bin.res`), or, when called outside the CLI (worker threads, test harnesses), lazy-loaded via the `getConfigJson` NAPI call.
- Handler registrations (`indexer.onEvent(...)`) land in `HandlerRegister.res` at module load time and are merged into `Config.t` on the next `Config.load()` (see `buildContractEvents`).
- Environment variables (`.env`) feed `Env.res`, consumed by `PgStorage` / `ClickHouse` for connection settings.

Persistence layer:

- `PgStorage.res` – low-level Postgres adapter.
- `Hasura.res` – Hasura metadata integration.
- `Persistence.res` – high-level persistence façade.
- `IO.res` – commits batched entity changes using the persistence layer. (should be refactored to use `PgStorage.res` and `Persistence.res`)

Data sourcing (fetch side):

- `ChainManager.res` – picks the next chain / block range to fetch. (manages multiple chain buffers)
- `ChainFetcher.res` – per-chain data source progress. (should be refactored in favor `FetchState.res` and `SourceManager.res`)
- `FetchState.res` – in-memory buffer and query bookkeeping. (per-chain)
- `SourceManager.res` – selects data source & handles fallbacks. (per-chain)

Event processing:

- `GlobalStateManager.res` – top-level scheduler:
  1. `NextQuery` – fetch more events.
  2. `ProcessEventBatch` – execute handlers - usually 5000-event batches.
- `EventProcessing.res` – runs handlers & builds in-memory entity updates.
- `IO.res` – flushes the batch to Postgres in a single transaction.

Monitoring & health:

- `Prometheus.res` – exports metrics.
- Health endpoints served by `Main.start`.

Quick dev tips:

- Library code under `packages/envio` → hot-recompile with `pnpm rescript -w`.
- Changes that affect emitted types (`packages/cli/src/hbs_templating/codegen_templates.rs`, schema, config) require rerunning `pnpm codegen` in the consuming scenario.

### Case study: per-address `startBlock`

Need to expose a `startBlock` setting for every contract address in `config.yaml`. The same pattern applies to most new config features.

1.  CLI (Rust) side
2.  Extend `config.yaml` by changing the user-facing structs in `human_config.rs` (add `start_block` inside the `address` object).
3.  Run `cargo test` – unit tests in `test/configs/*` should cover happy & failure cases.
4.  Regenerate JSON-schemas for docs & validation: `make update-schemas`.
5.  Mirror the new field in `system_config.rs`; convert it to an internal type that is easier for templates (e.g., `IndexingContract { address, start_block, abi, events }`).
6.  Pass the enriched contract structs into `hbs_templating/codegen_templates.rs`.
7.  Update the codegen output in `hbs_templating/codegen_templates.rs` (the `Indexer.res` builder for ReScript projects, the `.envio/types.d.ts` augmentation block for TypeScript) so per-address `startBlock` flows into the runtime.
8.  Add the field to `Config.res`.
9.  Compress the two previous arrays passed to `FetchState.res` `make` function (static vs dynamic contracts) into a single `array<IndexingContract>` that already contains `startBlock`.
10. Inside `FetchState.res` in `make` function create the initial block-partitions from the `startBlock` of each contract.
11. Compile changes in `packages/envio` by running `pnpm rescript` or `pnpm rescript -w` if you want to see changes live.
12. Test changes in `scenarios/test_codegen` by running `pnpm codegen` and `pnpm test`.

## Architecture Goal: Ports & Adapters (WIP)

> This is a direction we are actively moving toward, not the current state of
> the whole codebase. New work should lean this way; existing code is migrated
> incrementally. Expect both styles to coexist for a while.

We already apply ports & adapters at the external boundaries — `Persistence.storage`
and `Sink.t` are records of functions with swappable Postgres / ClickHouse
implementations. The goal is to extend the same inversion to the **internal**
indexer implementation, starting with `GlobalState.res` and its reducers, so the
domain logic stops reaching into infrastructure (notably the mutable
`InMemoryStore`) directly.

Conventions for the target shape:

- **Ports are domain verbs, not infrastructure objects.** A port is a single
  function expressed in domain language (`CommitBatch`, `WriteChainMetadata`,
  `Rollback`), with no knowledge of how storage is implemented. We do not model
  a generic `Store` object with `get` / `set` / `flush`.
- **Port types live in `Ports.res`.** Each port is a module exposing its own
  `input`, `output`, and `t = input => output` types. These are concrete domain
  types (alias `Internal` / `Batch` / `Persistence` types where they already
  exist). `Ports.res` depends only on leaf domain modules so it never forms a
  cycle.
- **Adapters live under `adapters/`** and hold the storage knowledge. An adapter
  is a `make` factory that takes the ports/infra it depends on as labeled
  arguments and returns a `Ports.X.t`:

  ```rescript
  // adapters/CommitBatchAdapter.res
  let make = (~inMemoryStore: InMemoryStore.t): Ports.CommitBatch.t =>
    input => /* storage orchestration here */
  ```

- **Dependencies are injected through `make` constructors wired once at a
  reusable root** — never reached via a global or a `Ctx.ports` bundle, and never
  via a shared ports record. The wiring lives in one factory so `Main`, the test
  indexer, and reducer unit tests can all build the graph with real or fake
  adapters. `GlobalState.injectedTaskReducer` is the existing precedent: it
  already takes its source-side verbs (`waitForNewBlock`, `executeQuery`) as
  labeled args.
- **Sync stays sync.** If an adapter has no asynchronous work, its port returns a
  plain value, not a `promise`. Don't make a verb async just to fit a uniform
  signature.

A goal of this migration is to make the indexer's main logic readable on its own
— the fetch/process/rollback flow expressed in domain verbs — without a hard
dependency on the storage implementation behind it.

## Update CLI Generated Docs

Navigate to the cli directory
`cd packages/cli`

To update all generated docs run

`make update-generated-docs`

To updated just the config json schemas
`make update-schemas`

Or to update just the cli help md file
`make update-help`

## Create templates

`cd` into folder of your choice and run

```sh
envio init
```

Then choose a template out of the possible options

```
? Which template would you like to use?
> "Gravatar"
[↑↓ to move, enter to select, type to filter]
```

Then choose a language from JavaScript, TypeScript or ReScript to write the event handlers file.

```
? Which language would you like to use?
> "JavaScript"
  "TypeScript"
  "ReScript"
[↑↓ to move, enter to select, type to filter
```

This will generate the config, schema and event handlers files according to the template and language chosen.

## Configure the files according to your project

Our greeter template [config.yaml](./packages/cli/templates/static/greeter_template/typescript/config.yaml) and [schema.graphql](./packages/cli/templates/static/greeter_template/shared/schema.graphql) is an example of how to layout a configuration file for indexing.

_Please refer to the [documentation website](https://docs.envio.dev) for a thorough guide on all [Envio](https://envio.dev) indexer features_

## Generate code according to configuration

Once you have configured the above files and deployed the contracts, the following can be used generate all the code that is required for indexing your project:

```sh
pnpm codegen
```

## Run the indexer

Once all the configuration files and auto-generated files are in place, you are ready to run the indexer for your project:

```sh
pnpm start
```

## View the database

To view the data in the database open http://localhost:8080/console.

Admin-secret for local Hasura is `testing`.

## Testing

### Running Tests in test_codegen

**Commands:**

```sh
cd scenarios/test_codegen
pnpm codegen  # Generate indexer code (only needed after config/schema changes)
pnpm test     # Run all tests
pnpm mocha --grep "test name pattern"  # Run specific tests
```

**Development workflow:**

- Changes to library code (`packages/envio`): Run `pnpm rescript -w` for live compilation
- Changes to templates or config: Run `pnpm codegen` then `pnpm test` in `scenarios/test_codegen`
