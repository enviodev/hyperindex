# Contributing to Envio

By submitting a Pull Request or making any contribution to this project, you automatically agree to and accept all terms outlined in our [Contributor License Agreement](./licenses/CLA.md). This includes all future contributions you may make to the project.

## Table of Contents

- [Installation](#installation)
- [Project Structure Overview](#project-structure-overview)
- [Generated Indexer Runtime Architecture](#generated-indexer-runtime-architecture)
- [Update CLI Generated Docs](#update-cli-generated-docs)
- [Create templates](#create-templates)
- [Configure the files according to your project](#configure-the-files-according-to-your-project)
- [Generate code according to configuration](#generate-code-according-to-configuration)
- [Run the indexer](#run-the-indexer)
- [View the database](#view-the-database)

## Installation

Install prerequisite tools:

1. Node.js (install v18) https://nodejs.org/en
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
cargo install --path codegenerator/cli --locked --debug
```

Command to see available CLI commands

```sh
envio --help
```

Alternatively you can add an alias in your shell config. This will allow you to test Envio locally without manual recompiling.

Go to your shell config file and add the following line:

```sh
alias lenvio="cargo run --manifest-path <absolute repository path>/hyperindex/codegenerator/cli/Cargo.toml --"
```

> `lenvio` is like `local envio` 😁

## Project Structure Overview

Envio is split into a Rust CLI and the generated indexer runtime.

Top-level folders:

- `codegenerator/cli` – Rust source of the Envio CLI (`Cargo.toml` lives here).
  - `src/commands.rs` – dispatches sub-commands using Clap.
  - `src/executor/` – implementation details for each command.
  - `src/config_parsing/` – configuration loading pipeline:
    - `human_config.rs` → reads user `config.yaml`.
    - `system_config.rs` → converts user config into the internal representation.
  - `src/hbs_templating/codegen_templates.rs` – prepares data for Handlebars and writes the `generated/` directory.
  - `templates/` – code scaffold used during generation (`dynamic/` for Handlebars, `static/` for raw files).

Main CLI commands:

1. `init` – interactive project scaffolding (`src/executor/init.rs`, `src/cli_args/interactive_init/`).
2. `codegen` – parses config, builds the internal model, then calls templates to create the `generated/` indexer runtime.
3. `start` – runs the already generated runtime code.
4. `dev` – detects changes; if anything changed it runs `codegen` and then `start`, otherwise just `start`.

Generated indexer runtime locations:

1. Library-ified code: `codegenerator/cli/npm/envio` (ReScript/TypeScript). Use `pnpm rescript-w` for live recompilation; no `pnpm codegen` needed.
2. Static scaffold: `codegenerator/cli/templates/static/codegen` and dynamic templates in `codegenerator/cli/templates/dynamic/codegen` (requires `pnpm codegen` after edits).
3. Scenario & regression tests: `scenarios/` (e.g. `scenarios/test_codegen`). Run `pnpm codegen` then `pnpm test`. (You don't need to run `pnpm codegen` when changing librariefied code).
4. Quick-iteration trick when working with static code a lot: open `scenarios/test_codegen/generated`, run `pnpm rescript -w`, adjust files, then copy changes back into templates.

Navigation cheat-sheet (useful for code search / AI):

- CLI entry point: `codegenerator/cli/src/lib.rs`
- Command definitions: `codegenerator/cli/src/commands.rs`
- Arg parsing: `codegenerator/cli/src/cli_args/`
- EVM helpers: `codegenerator/cli/src/evm/`
- Fuel helpers: `codegenerator/cli/src/fuel/`

## Generated Indexer Runtime Architecture

All code below is generated into your project’s `generated/` folder or located in the reusable library components in `codegenerator/cli/npm/envio`.

Entry point:

- `Index.res` – launched by `pnpm start`. Responsibilities:
  - Parses CLI flags (`--tui-off`, etc.).
  - Loads runtime configuration (`Config.res`).
  - Starts an Express server that serves `/metrics`, `/health`, and the Development Console endpoints.
  - Intitializes the Persistence layer (Postgres + Hasura).
  - Calls `RegisterHandlers.res` to wire in user-defined event handlers.
  - Loads initial state (to resume from a previous run).
  - Spawns the `GlobalStateManager.res` which orchestrates fetch & process loops.

Configuration layer:

- `Config.res` – strongly typed runtime config. Values come from:
  - Environment variables (`.env`).
  - Constants injected by `RegisterHandlers.res` (derived from `config.yaml`).
- Also sets up the Persistence adapter (Postgres + Hasura).

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
- Health endpoints served by `Index.res`.

Quick dev tips:

- Library code under `npm/envio` → hot-recompile with `pnpm rescript -w`.
- Changes inside generated require rerunning `pnpm codegen` (unless you are in the quick-iteration workflow described above).

### Case study: per-address `startBlock`

Need to expose a `startBlock` setting for every contract address in `config.yaml`. The same pattern applies to most new config features.

1.  CLI (Rust) side
2.  Extend `config.yaml` by changing the user-facing structs in `human_config.rs` (add `start_block` inside the `address` object).
3.  Run `cargo test` – unit tests in `test/configs/*` should cover happy & failure cases.
4.  Regenerate JSON-schemas for docs & validation: `make update-schemas`.
5.  Mirror the new field in `system_config.rs`; convert it to an internal type that is easier for templates (e.g., `IndexingContract { address, start_block, abi, events }`).
6.  Pass the enriched contract structs into `hbs_templating/codegen_templates.rs`.
7.  Update the Handlebars context used by `templates/dynamic/codegen/src/RegisterHandlers.res.hbs` so the generated `RegisterHandlers.res` forwards `startBlock`.
8.  Add the field to `Config.res`.
9.  Compress the two previous arrays passed to `FetchState.res` `make` function (static vs dynamic contracts) into a single `array<IndexingContract>` that already contains `startBlock`.
10. Inside `FetchState.res` in `make` function create the initial block-partitions from the `startBlock` of each contract.
11. Compile changes in `npm/envio` by running `pnpm rescript` or `pnpm rescript -w` if you want to see changes live.
12. Test changes in `scenarios/test_codegen` by running `pnpm codegen` and `pnpm test`.

## Update CLI Generated Docs

Navigate to the cli directory
`cd codegenerator/cli`

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

Our greeter template [config.yaml](./codegenerator/cli/templates/static/greeter_template/typescript/config.yaml) and [schema.graphql](./codegenerator/cli/templates/static/greeter_template/shared/schema.graphql) is an example of how to layout a configuration file for indexing.

_Please refer to the [documentation website](https://docs.envio.dev) for a thorough guide on all [Envio](https://envio.dev) indexer features_

## Generate code according to configuration

Once you have configured the above files and deployed the contracts, the following can be used generate all the code that is required for indexing your project:

```sh
envio codegen
```

## Run the indexer

Once all the configuration files and auto-generated files are in place, you are ready to run the indexer for your project:

```sh
pnpm start
```

## View the database

To view the data in the database open http://localhost:8080/console.

Admin-secret for local Hasura is `testing`.
