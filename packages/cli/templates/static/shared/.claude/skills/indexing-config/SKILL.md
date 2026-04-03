---
name: indexing-config
description: >-
  Use when writing or editing config.yaml. Chain/contract structure, addresses,
  start_block, event selection, field_selection, custom event names, env vars,
  address_format, schema/output paths, YAML validation, and deprecated options.
---

# Config Reference (config.yaml)

## Structure Overview

```yaml
name: my-indexer
description: Optional description
schema: schema.graphql         # custom path (default: schema.graphql)
output: generated/             # custom output path (default: generated/)
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

# Factory-registered — see indexing-factory skill
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

Global `field_selection` is at the root level (sibling to `contracts` and `chains`). Per-event `field_selection` is directly under the event entry. See `indexing-transactions` skill for full field lists.

## Environment Variables

```yaml
rpc:
  - url: ${ENVIO_RPC_URL}                    # required — errors if missing
  - url: ${ENVIO_RPC_URL:-http://localhost:8545}  # with default value
```

Works in any string value in config. Set via `.env` file or shell environment.

**IMPORTANT:** All environment variables MUST use the `ENVIO_` prefix (e.g., `ENVIO_RPC_URL`, not `RPC_URL`). The hosted service requires the `ENVIO_` prefix — variables without it will not be available at runtime.

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

## RPC Configuration

RPC tuning parameters are documented in the `indexing-performance` skill.

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
