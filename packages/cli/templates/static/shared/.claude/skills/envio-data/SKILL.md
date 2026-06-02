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
- **--where**: JSON5 with the indexer `where` syntax. Filter on any field with
  `_eq`, `_in`, `_gte`, `_lte`, `_gt`, `_lt`.

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

Get the current chain height:

```bash
envio data knownHeight --chain=arbitrum-one
```
