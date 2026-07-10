---
name: indexer-configuration
description: >-
  Use when writing or editing config.yaml. Chain/contract structure, addresses,
  start_block, event selection, field_selection, custom event names, env vars,
  address_format, schema/output paths, YAML validation, and deprecated options.
metadata:
  managed-by: envio
---

# Config Reference (config.yaml)

## Structure Overview

```yaml
name: my-indexer
description: Optional description
schema: schema.graphql         # custom path (default: schema.graphql)
address_format: checksum       # checksum (default) | lowercase

contracts:
  - name: MyContract
    abi_file_path: ./abis/MyContract.json
    handler: ./src/EventHandlers.ts  # optional — auto-discovered from src/handlers/
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)

chains:
  - id: 1
    start_block: 0
    contracts:
      - name: MyContract
        address: "0x1234..."
```

Uses `chains` (not `networks`) and `max_reorg_depth` (not `confirmed_block_threshold`).

## Contract Addresses

```yaml
# Single address
- name: Token
  address: "0x1234..."

# Multiple addresses
- name: Token
  address:
    - "0xaaa..."
    - "0xbbb..."

# No address — wildcard indexing (all contracts matching ABI)
- name: Token
  # address omitted — indexes all matching events chain-wide

# Factory-registered — see indexer-factory skill
```

For proxied contracts, use the **proxy address** (where events emit), not the implementation.

## start_block

```yaml
chains:
  - id: 1
    start_block: 0            # 0 = HyperSync auto-detects first event block
    contracts:
      - name: Token
        address: "0x1234..."
        start_block: 18000000  # per-contract override (takes precedence)
```

`start_block: 0` with HyperSync skips empty blocks automatically.

## Custom Event Names

When two events share the same name (different signatures), disambiguate:

```yaml
events:
  - event: Transfer(address indexed from, address indexed to, uint256 value)
    name: TransferERC20
  - event: Transfer(address indexed from, address indexed to, uint256 indexed tokenId)
    name: TransferERC721
```

## field_selection

Request additional transaction/block fields globally or per event:

```yaml
# Global (root level — applies to all events)
field_selection:
  transaction_fields:
    - hash
    - from
    - to
  block_fields:
    - number
    - timestamp

contracts:
  - name: MyContract
    events:
      # Per-event (overrides global for this event)
      - event: Transfer(address indexed from, address indexed to, uint256 value)
        field_selection:
          transaction_fields:
            - hash
            - from
            - to
            - gasPrice
```

Global `field_selection` is at the root level (sibling to `contracts` and `chains`). Per-event `field_selection` is directly under the event entry. See `indexer-transactions` skill for full field lists.

## multichain

Root-level option controlling how entities relate across chains:

```yaml
multichain: isolated # or unordered (default)
```

- `unordered` (default) — events are processed as soon as they arrive from each chain and entities are shared across chains.
- `isolated` — every chain's entities are kept isolated from each other. Each entity table gets a non-nullable chain id column (`chainId`, or `chain_id` with `column_name_format: snake_case`), so entity fields with that name are rejected.

Supported for all ecosystems (EVM, Fuel, SVM).

## Environment Variables

```yaml
rpc:
  - url: ${ENVIO_RPC_URL}                    # required — errors if missing
  - url: ${ENVIO_RPC_URL:-http://localhost:8545}  # with default value
  - url: ${ENVIO_RPC_URL:-${ENVIO_FALLBACK_RPC_URL}}  # nested: fall back to another var
```

Works in any string value in config. Set via `.env` file or shell environment. The default after `:-` (or `-`) may itself be a `${...}` expression and is only resolved when the default is actually used.

**IMPORTANT:** All environment variables MUST use the `ENVIO_` prefix (e.g., `ENVIO_RPC_URL`, not `RPC_URL`). The hosted service requires the `ENVIO_` prefix — variables without it will not be available at runtime.

## Runtime Environment Variables

Set on the indexer process (not interpolated into config.yaml):

- `ENVIO_TUI` — `true` forces the terminal UI on, `false` forces it off. Unset (default) auto-disables under agents, CI, and non-TTY stdout, so plain `pnpm dev` produces line-buffered output suitable for log capture without manual intervention.

## YAML Validation

Add at top of file for IDE schema validation:

```yaml
# yaml-language-server: $schema=./node_modules/envio/evm.schema.json
```

## Deprecated Options (Do NOT Use)

- `loaders` / `preload_handlers` — replaced by async handler API
- `preRegisterDynamicContracts` — replaced by `contractRegistrations` in factory pattern
- `event_decoder` — removed
- `rpc_config` — replaced by `rpc:` under chains
- `unordered_multichain_mode` — removed

> If something is unclear, use the `envio-docs` skill to search and read the latest documentation.
