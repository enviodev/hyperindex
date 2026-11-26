# Fetching architecture

How a chain's data gets from a backend into the indexer, and where each piece
lives. Paths are relative to `packages/`.

## Layers

Imports point down. `cli/src/layers.rs` fails the build when a Rust file
imports from a layer above it.

| Layer | Rust (`cli/src/`) | ReScript (`envio/src/`) |
| --- | --- | --- |
| Loop and planning | | `IndexerLoop`, `ChainState`, `ChainFetching`, `FetchState` |
| Source control: which source, retries, heights | | `sources/SourceManager`, `sources/HeightFeed`, `sources/HeightStream`, `sources/HyperSyncSSE`, `sources/EvmRpcWs` |
| Source contract | `sources/failure.rs`, `sources/native.rs` | `sources/Source`, `sources/NativeSource`, `sources/ChainSources`, `sources/SimulateSource` |
| Clients | `sources/evm_hypersync/`, `sources/evm_rpc/`, `sources/fuel_hypersync/`, `sources/svm_hypersync/` | |
| Chain data | `chain_buffer/` (`tables/`, `matching/`, `selection/`, `decode/`), `address_store/` | `sources/ChainBuffer`, `sources/BufferPage`, `sources/ChainRegistrations`, `sources/AddressStore` |
| Ecosystems | `evm/`, `fuel/`, `svm/` | `Evm`, `Fuel`, `Svm` and their `*EventItem` modules |

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

The environment is read where the indexer starts: `Env.res` reads it, and
`Config.fromPublic` puts what sources need on each chain's source config
(`Config.hyperSync`, an RPC's `syncConfig`). Rust reads the environment only
through `cli/src/env.rs`, at its own entry points.
