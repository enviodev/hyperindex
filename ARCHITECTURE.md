# Fetching architecture

How a chain's data gets from a backend into the indexer, and where each piece
lives. Paths are relative to `packages/`.

## Layers

Imports point down. `cli/src/layers.rs` fails the build when a Rust file
imports from a layer above it.

| Layer | Rust (`cli/src/`) | ReScript (`envio/src/`) |
| --- | --- | --- |
| Loop | | `run/IndexerLoop`, `run/CrossChainState`, `run/ChainState`, `fetching/ChainFetching` |
| Source control: which source, retries, heights | | `sources/SourceManager`, `sources/heights/` (`HeightFeed`, `HeightStream`, `HyperSyncSSE`, `EvmRpcWs`) |
| Source contract | `sources/failure.rs`, `sources/source.rs` | `sources/Source`, `sources/ChainSources`, `sources/SimulateSource` |
| Planning: what to fetch next | `indexing_plan/` (`chain`, `pipeline`, `budget`, `coverage`) | `fetching/IndexingPlan` |
| Clients | `sources/evm_hypersync/`, `sources/evm_rpc/`, `sources/fuel_hypersync/`, `sources/svm_hypersync/` | |
| Chain data | `chain_buffer/` (`tables/`, `matching/`, `selection/`, `decode/`), `address_store/` | `chainBuffer/` (`ChainBuffer`, `BufferPage`, `ChainRegistrations`, `AddressStore`) |
| Ecosystems | `ecosystems/` (`evm/`, `fuel/`, `svm/`) | `ecosystems/` (`Evm`, `Fuel`, `Svm` and their `*EventItem` modules) |

The ecosystem modules import nothing from the runtime above them; the chain
data imports no source; nothing below the source contract reads the
environment.

## The indexing plan

One napi `IndexingPlan` per worker plans every chain's fetching, in Rust. Each
tick it computes the work from three tables per chain, keeping nothing derived:

- **Needs**: what the chain must fetch, and from where. A need reads logs for a
  group of addresses, a list of addresses or address-free, or reads blocks or
  transactions. It has a floor, an optional `to_block` (its contract's
  `end_block`, or the block a catch-up owes up to) and what it has learned:
  density and each source's range capacity.
- **Coverage**: per need, every block through `covered_through` plus the
  ranges that finished ahead of it. It moves only to the block a source
  reports.
- **Work in flight**: the requests out, each naming the needs it serves, its
  range and the items it reserves. A rollback drops them all by bumping a
  generation, so a stale response is recognised and discarded.

Nothing is merged, split, retired or renumbered. A registration joins its
contract's open group where that group has been requested through, and owes
the blocks below as a catch-up by address list. A contract past the
address-free threshold ends its groups at the block they were requested
through, and one address-free need takes over from there. Once every need is
within 200 blocks of the head, one request serves them all, so the chain asks
for each new block once.

`pipeline.rs` turns the tables into candidate requests (holes first, then
chunks sized by the learned capacity, or a probe), and `budget.rs` shares the
cross-chain item budget between chains and accepts candidates in block order.
The plan answers with a `FetchRequest` handle that the source reads directly:
its range, selection and addresses. The plan also holds each chain's
contractRegister backlog and the block the chain is ready through.

## The source contract

Every production source is one Rust `Source`, built for a chain by
`ChainSources.fromConfig` from the chain's source config. ReScript wraps
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
| `WrongSourceForQuery({message})` | tries another source for this query |
| `Unusable({message, blockNumber?})` | stops using the source |

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
