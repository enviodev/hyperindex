# Why Workers for Test Indexer

## Status

Accepted

## Context

The test indexer (`createTestIndexer`) needs to provide isolation between handler module invocations. Several challenges drove this decision:

- Users may use global variables in their handler modules
- Each `indexer.process()` call should simulate a clean indexer state, as if the indexer had restarted
- Global singleton modules (Prometheus client, logger) are not designed for multiple isolated runs within a single process

Without isolation, state from one test run could leak into another, causing flaky tests and behavior that doesn't match production.

## Alternatives Considered

- **Refactor all global singletons**: Would require significant changes to Prometheus client, logger, and other modules to support reset/isolation. High effort with risk of introducing bugs in production code paths.
- **ESM cache invalidation**: Reset module cache using `?nonce=x` query params on imports. More brittle and problematic for parallel tests - handler registration is a global singleton that would conflict with top-level await, and indexer state couldn't be split between concurrent runs.
- **Process-level isolation**: Spawn new processes instead of workers. Higher overhead and more complex IPC.

## Decision

Use Node.js worker threads for each `indexer.process()` call. The worker runs the handler code in complete isolation:

- Handler modules are freshly imported in each worker
- Global variables start fresh every time
- Singleton modules get new instances automatically

The main thread maintains the storage state and communicates with workers via message passing (`TestIndexerProxyStorage`).

## Consequences

### Positive

- Complete module isolation between test runs without any production code changes
- Each `process()` call simulates a clean indexer state after restart
- Enables running multiple test indexers in parallel (each has its own workers)
- Postpones refactoring of global singleton modules to a later time

### Negative

- Potential performance overhead from constantly creating new workers
- Workers are used for isolation, not optimization - this is an intentional trade-off
- IPC serialization overhead for storage operations between worker and main thread
