# Fetching architecture

How a chain's data gets from a backend into the indexer, and where each piece
lives. Paths are relative to `packages/`.

## Layers

Imports point down. `cli/src/layers.rs` fails the build when a Rust file
imports from a layer above it.

| Layer | Rust (`cli/src/`) | ReScript (`envio/src/`) |
| --- | --- | --- |
| Loop and planning | | `run/IndexerLoop`, `run/ChainState`, `fetching/ChainFetching`, `fetching/FetchState` |
| Source control: which source, retries, heights | | `sources/SourceManager`, `sources/heights/` (`HeightFeed`, `HeightStream`, `HyperSyncSSE`, `EvmRpcWs`) |
| Source contract | `sources/failure.rs`, `sources/native.rs` | `sources/Source`, `sources/NativeSource`, `sources/ChainSources`, `sources/SimulateSource` |
| Clients | `sources/evm_hypersync/`, `sources/evm_rpc/`, `sources/fuel_hypersync/`, `sources/svm_hypersync/` | |
| Chain data | `chain_buffer/` (`tables/`, `matching/`, `selection/`, `decode/`), `address_store/` | `chainBuffer/` (`ChainBuffer`, `BufferPage`, `ChainRegistrations`, `AddressStore`) |
| Ecosystems | `ecosystems/` (`evm/`, `fuel/`, `svm/`) | `ecosystems/` (`Evm`, `Fuel`, `Svm` and their `*EventItem` modules) |

The ecosystem modules import nothing from the runtime above them; the chain
data imports no source; nothing below the source contract reads the
environment.

## The source contract

Every production source is one Rust `NativeSource`, built for a chain by
`NativeSource.makeChainSources` from the chain's source config. ReScript wraps
it as a `Source.t`; tests and the simulate source implement `Source.t` in JS.

A call answers with a `Source.outcome`: a `result` and the `requestStats` the
call made, which count towards the source's metrics either way. An expected
failure is a `Source.failure`, which crosses napi as a tagged object in the
ReScript variant's own shape:

| Failure | SourceManager does |
| --- | --- |
| `RateLimited({resetMs})` | waits for the reset, asks again |
| `BehindHead({blockNumber})` | backs off quietly, fails over after 12 tries |
| `NarrowRange({toBlock, attemptedToBlock})` | asks again for the narrower range at once |
| `Backoff({message, backoffMillis?, cause?})` | waits `backoffMillis`, or its own schedule, and asks again |
| `WrongSourceForQuery({message, cause?})` | tries another source for this query |
| `Unusable({message, blockNumber?, cause?})` | stops using the source |

An exception escaping a source is a bug, and stops the indexer.

Clients never retry or sleep themselves: every wait runs on SourceManager's
clock, which tests move by hand.

## Configuration

ReScript never reads the environment. Rust reads and validates every variable
the runtime uses in `cli/src/indexer_env.rs` (through `cli/src/env.rs`, the
one module that touches it), and `Config.fromPublic` takes the result as
`config.env` (`IndexerEnv.t`). Sources get theirs on each chain's source config
(`Config.hyperSync`, an RPC's `syncConfig`).

## Where the rest lives

ReScript (`envio/src/`): entry points (`Envio`, `Api`, `Bin`, `Main`, `Core`,
`Config`, `IndexerEnv`, `Internal`) sit at the root; `run/` is the process and
its whole-indexer state (worker, supervisor, server, metrics); `processing/`
runs handlers over a batch and rolls back; `handlers/` loads and registers user
code; `storage/` writes and reads (`storage/db/` holds tables and SQL);
`testing/` is `createTestIndexer` and simulate; `utils/` is shared primitives.

Rust (`cli/src/`): `storage/` is the storage service with its backends
(`postgres/`, `clickhouse/`, `columnar/`); `codegen/` renders the generated
project files; `config_parsing/` turns config.yaml into the config the runtime
reads; `executor/`, `cli_args/` and `commands.rs` are the CLI.
