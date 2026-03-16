## Plan: Typesafe ecosystem-scoped simulate API

### 1. Codegen: Add events to contract types (Rust)
**File:** `codegen_templates.rs`

Change `EvmContracts`/`FuelContracts` from `{ "Gravatar": {} }` to `{ "Gravatar": { "NewGravatar": {}; "UpdatedGravatar": {} } }`.

Events from `contract.events` already available in codegen context.

### 2. index.d.ts: Ecosystem-scoped typesafe simulate types

- `SimulateContractEvent<Contracts>` mapped type → `{ contract: C; event: E; ... }` union
- `EvmSimulateEventItem` — with srcAddress, logIndex, block, transaction
- `FuelSimulateEventItem` — union of `FuelSimulateLogItem`, `FuelSimulateMintItem`, `FuelSimulateBurnItem`, `FuelSimulateTransferItem`, `FuelSimulateCallItem`
- No simulate for SVM
- `TestIndexerChainConfig` generic over simulate item type
- `TestIndexerProcessConfig` maps ecosystem-specific chain IDs to ecosystem-specific chain configs

### 3. Types.ts.hbs: Update IndexerConfigTypes
Contracts values now have event keys — update constraint.

### 4. Move simulate setup from Main to TestIndexer
- `initTestWorker`: parse simulate items, create SimulateSource, override config sourceConfig
- Remove `~processConfig` from `Main.start()`

### 5. Update tests

### 6. Run compiler + tests
