---
name: envio-data
description: >-
  Query raw blockchain data — block ranges, event lookups, transactions, chain height —
  via `envio data`. Use instead of curl or web searches for block discovery.
metadata:
  managed-by: envio
---

# `envio data`

**Do NOT web-search for block ranges.** Use `envio data` instead.

```bash
envio data <field>... --chain=<id|name> [--where='<json5>']
```

- **Fields**: any EVM block/log/transaction field, plus `knownHeight`.
  Examples: `block.number`, `log.srcAddress`, `transaction.hash`.
  Case-insensitive — `gasLimit`, `gas_limit`, `GASLIMIT` all work.
- **--chain**: numeric id (`8453`) or name (`base`, `arbitrum-one`).
- **--where**: JSON5, grouping fields under `block`, `transaction`, `log`.
  Any field can be filtered:
  - Match with a scalar, an array, `_eq`, or `_in` (e.g. `log: { srcAddress: "0x..." }`).
  - Compare numeric fields with `_gt`, `_gte`, `_lt`, `_lte` (e.g. `transaction: { value: { _gt: 1000000000000000000 } }`).
  - Comparison ops are numeric-only; hex/bool fields take only `_eq`/`_in`.
  - `block.timestamp` is unix **seconds**, resolved to a block range with a quick
    pre-flight lookup — use it instead of guessing block numbers for a date.
    A scalar/`_eq`/`_in` resolves to the latest block at or before each timestamp
    (like Etherscan's `closest=before`); ranges are half-open: `_gte` start is
    inclusive, `_lt` end is exclusive.

## Examples

Find when a contract started emitting an event:

```bash
envio data block.number log.transactionHash \
  --chain=base \
  --where='{
    block: { number: { _gte: 0 } },
    log: { srcAddress: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" },
  }'
```

Filter on any field, including numeric comparisons:

```bash
envio data transaction.hash transaction.value \
  --chain=base \
  --where='{
    block: { number: { _gte: 1000000, _lt: 1000100 } },
    transaction: { value: { _gt: 1000000000000000000 } },
  }'
```

Find the block at a unix timestamp — the latest block at or before it
(e.g. 2024-01-01 00:00:00 UTC = `1704067200`):

```bash
envio data block.number block.timestamp \
  --chain=base \
  --where='{ block: { timestamp: 1704067200 } }'
```

Get transactions in a time range (unix seconds, `_gte`/`_lt`):

```bash
envio data transaction.hash transaction.from transaction.value \
  --chain=base \
  --where='{
    block: { timestamp: { _gte: 1704067200, _lt: 1704153600 } },
    transaction: { value: { _gt: 0 } },
  }'
```

Get the current chain height:

```bash
envio data knownHeight --chain=arbitrum-one
```
