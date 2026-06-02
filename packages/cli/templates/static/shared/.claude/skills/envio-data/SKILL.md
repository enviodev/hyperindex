---
name: envio-data
description: >-
  Query raw blockchain data — block ranges, event lookups, transactions, chain height —
  via `envio data`. Use instead of curl or web searches for block discovery.
metadata:
  managed-by: envio
---

# `envio data`

Query blocks, logs, and transactions on EVM chains. Uses the same `where`
syntax as indexer filters. **Do NOT web-search for block ranges.**

```bash
envio data <field>... --chain=<id|name> [--where='<json5>']
```

- **Fields**: `block.number`, `log.srcAddress`, `transaction.hash`, `knownHeight`, etc.
  Case-insensitive — `gasLimit`, `gas_limit`, `GASLIMIT` all work.
- **--chain**: numeric id (`8453`) or name (`base`, `arbitrum-one`).
- **--where**: JSON5 with the indexer `where` operator syntax.

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

## Filter operators

| Form | Meaning |
|---|---|
| `srcAddress: "0xabc"` | equals |
| `srcAddress: ["0xa", "0xb"]` | in set |
| `block.number._gte: 1000` | inclusive lower bound |
| `block.number._lte: 2000` | inclusive upper bound |
| `block.number._gt` / `_lt` | exclusive variants |
