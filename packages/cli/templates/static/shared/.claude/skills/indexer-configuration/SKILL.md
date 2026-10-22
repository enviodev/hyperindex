---
name: indexer-configuration
description: >-
  Use when writing or editing config.yaml. Chain/contract structure, addresses,
  start_block, event selection, field_selection, custom event names, env vars,
  address_format, bytes_type, strict_hex_type, schema path, YAML validation, and
  deprecated options.
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
bytes_type: hex                # hex (default) | uint8array — see bytes_type
strict_hex_type: true          # false (default) | true — see strict_hex_type

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

# No address
- name: Token
  # address omitted
```

A contract without an address indexes nothing until either
`indexer.contractRegister` adds addresses (see the `indexer-factory` skill) or
its handler passes `wildcard: true`, which indexes every matching event on the
chain (see the `indexer-wildcard` skill). Omitting the address alone is not
wildcard.

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

Selects transaction/block fields for every handler of an event — at the root
level (sibling to `contracts` and `chains`), or under an event entry. Prefer the
handler's `fields` option, which lists them next to the code that reads them:

```yaml
field_selection:
  transaction_fields: [hash, from]
  block_fields: [miner]
```

`block_fields` can't list `number`, `timestamp` or `hash`: they're always
included, and codegen rejects them as unknown variants. See the
`indexer-transactions` skill for `fields` and the full field lists.

## bytes_type

How the `Bytes` scalar in schema.graphql reaches handlers and storage:

- `hex` (default): `0x`-prefixed hex strings, stored as text.
- `uint8array`: `Uint8Array` values in handlers, stored as raw bytes (`BYTEA` in
  Postgres, `String` in ClickHouse). Halves the storage of addresses and hashes.

```yaml
bytes_type: uint8array
```

Available on EVM and Fuel. SVM always uses `Uint8Array` and has no option.
Changing it changes the column types, so resync from scratch.

## strict_hex_type

Makes the `Hex` type from `envio` mean `` `0x${string}` `` instead of `string`,
so a plain `string` is rejected where a hex value is expected. `Hex` types bytes
params (including `where` filters and test `simulate` params), block and
transaction hashes, and `Bytes` fields. `StrictHex` is always `` `0x${string}` ``.

```yaml
strict_hex_type: true
```

Off by default; `envio init` turns it on for new projects. Available on EVM and
Fuel. Types only, so no resync is needed.

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
- `preRegisterDynamicContracts` — removed; register factory-created addresses with `indexer.contractRegister` (see `indexer-factory`)
- `event_decoder` — removed
- `rpc_config` — replaced by `rpc:` under chains
- `unordered_multichain_mode` — removed

> If something is unclear, use the `envio-docs` skill to search and read the latest documentation.
