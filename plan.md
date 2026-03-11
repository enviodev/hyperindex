# Refactoring Plan: Replace generated schema-based field selection with string arrays

## Current Architecture
- Codegen generates per-event `blockSchema` and `transactionSchema` with rescript-schema
- Sources use `S.classify` on schemas to extract field items, then match against field registries
- HyperSync uses `Utils.Schema.getNonOptionalFieldNames` and `getCapitalizedFieldNames` to build HyperSync field selection
- RPC uses `S.classify` to get `Object({items})`, then classifies each `item.location` against the registry

## Goal
Replace generated rescript-schema with string arrays passed via `internal.config.json` → `Config.res`. Sources use mapping dicts for HyperSync field names and static nullable sets.

## Steps

### 1. Rust: add field names to `internal.config.json`
**Files: `codegen_templates.rs`**

- Add to `InternalEvmConfig`:
  - `global_block_fields: Vec<String>` — camelCase field names from global FieldSelection
  - `global_transaction_fields: Vec<String>`
- Add to `InternalContractEventItem`:
  - `block_fields: Option<Vec<String>>` — per-event custom field selection (skip_serializing_if None)
  - `transaction_fields: Option<Vec<String>>`
- In JSON generation (~line 1781), populate from `config_event.field_selection` and `cfg.field_selection`

### 2. Config.res: parse field names from JSON
**File: `Config.res`**

- Update `publicConfigEvmSchema` to parse `globalBlockFields` and `globalTransactionFields`
- Update `contractEventItemSchema` to parse optional `blockFields` and `transactionFields`
- Expose parsed field names so they flow into event config construction

### 3. Internal.res: replace schemas with string arrays
**File: `Internal.res`**

- In `evmEventConfig`:
  - Remove `blockSchema: S.schema<eventBlock>` and `transactionSchema: S.schema<eventTransaction>`
  - Add `blockFieldNames: array<string>` and `transactionFieldNames: array<string>`
  - Keep `selectedBlockFields` / `selectedTransactionFields` (lookup dicts for proxy)

### 4. Indexer.res.hbs: remove schema generation, use Config-provided field names
**File: `Indexer.res.hbs`**

- Remove `module Block` (type + schema) and `module Transaction` (type + schema)
- Remove per-event `blockSchema`/`transactionSchema` code generation (both custom schema inline and `Block.schema`/`Transaction.schema` references)
- In `register()`, replace `blockSchema`/`transactionSchema` with `blockFieldNames`/`transactionFieldNames` from parsed config
- Keep `selectedBlockFields`/`selectedTransactionFields` lookup dicts

### 5. Rust codegen: remove FieldSelection template struct
**File: `codegen_templates.rs`**

- Remove `FieldSelection` template struct (`block_type`, `block_schema`, `transaction_type`, `transaction_schema`)
- Remove `FieldSelection::new()`, `FieldSelection::global_selection()`, `FieldSelection::aggregated_selection()`
- Remove `field_selection` from template context (Handlebars)
- Remove `block_schema_code`/`transaction_schema_code` generation in `EventTemplate`
- Keep `selected_fields_code` generation (for `selectedBlockFields`/`selectedTransactionFields` proxy dicts) — or move this to Config.res too

### 6. RpcSource: use string arrays instead of S.classify
**File: `RpcSource.res`**

- `makeThrowingGetEventBlock`: accept `~blockFieldNames: array<string>` instead of `~blockSchema`
  - Iterate `blockFieldNames`, look up each in registry
  - Cache: use `Map<array<string>, fn>` keyed by array reference (created once per event config, same ref reused)
- `makeThrowingGetEventTransaction`: accept `~transactionFieldNames: array<string>` instead of `~transactionSchema`
  - Same pattern
- Call sites: pass `eventConfig.blockFieldNames` / `eventConfig.transactionFieldNames`

### 7. RpcSource: add HyperSync mapping and nullability info to field registries
**File: `RpcSource.res`**

- Extend `blockFieldDef` and `fieldDef` with:
  - `hyperSyncField: HyperSyncClient.QueryTypes.blockField` (or `transactionField`) — maps config name → HyperSync variant
  - `isNullable: bool` — whether the field is inherently optional
- Hardcode these close to existing field definitions in `makeBlockFieldRegistry` / `makeFieldRegistry`
- Export helpers: `getHyperSyncBlockField(string) => option<blockField>`, `isNullableBlockField(string) => bool` (or just expose the registries)

### 8. HyperSyncSource: use mapping from registries
**File: `HyperSyncSource.res`**

- In `getSelectionConfig`:
  - Replace `blockSchema->Utils.Schema.getNonOptionalFieldNames` → filter `blockFieldNames` using registry's `isNullable`
  - Replace `blockSchema->Utils.Schema.getCapitalizedFieldNames` → map `blockFieldNames` through registry's `hyperSyncField`
  - Same for transaction

### 9. Remove Utils.Schema helpers
**File: `Utils.res`**

- Remove `getNonOptionalFieldNames` and `getCapitalizedFieldNames` (no longer needed)

### 10. Validate & test
- Run `pnpm rescript` in envio package
- Regenerate test_codegen with CLI
- Run `pnpm vitest run`

## Unresolved Questions

1. **`selectedBlockFields`/`selectedTransactionFields` proxy dicts**: Currently generated inline in Indexer.res.hbs from Rust. Should these also move to Config.res (derived from the field name arrays), or keep as codegen? Moving to Config.res is more consistent — derive them from `blockFieldNames`/`transactionFieldNames` at runtime.
