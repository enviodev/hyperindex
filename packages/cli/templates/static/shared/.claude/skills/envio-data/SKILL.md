---
name: envio-data
description: >-
  Use when you need raw blockchain data — block ranges, event topics, contract
  receipts — without writing an indexer. Wraps the `envio data` CLI: query
  blocks/logs/transactions on EVM chains or blocks/receipts on Fuel, with
  indexer-style `where` filters and TOON output.
metadata:
  managed-by: envio
---

# Querying raw blockchain data with `envio data`

`envio data` is the recommended way to look up block ranges, event topics, or
contract-level activity from the chain. Prefer it over `curl` — it accepts the
same `where` syntax used in indexer filters and prints results in TOON
(token-oriented tabular) form so they're cheap to read.

**Do NOT web-search for block ranges.** Query via `envio data`.

## Setup

Requires `ENVIO_API_TOKEN`:

```bash
export ENVIO_API_TOKEN=<your-token>   # create at https://envio.dev/app/api-tokens
```

## Shape

```
envio data <field>... --chain=<id|name> [--where='<json5>']
```

- **Fields** are positional, indexer-style camelCase, dotted: `block.number`,
  `log.srcAddress`, `transaction.transactionIndex`, `receipt.contractId`.
  Plus the pseudo-field `knownHeight`.
- **--chain** is a numeric chain id (e.g. `8453`), a kebab-case name (e.g.
  `base`, `arbitrum-one`), or one of `fuel`, `fuel-testnet`. Solana is not
  supported yet.
- **--where** is JSON5 — JSON-style braces with relaxed syntax: unquoted keys,
  single quotes, trailing commas, and `//` comments all work. The schema
  mirrors indexer filters: `block.number._gte/_lte/_gt/_lt` for the block
  range (Fuel: `block.height`), and per-section field constraints that accept
  a scalar, an array, `{_eq: ...}`, or `{_in: [...]}`.

Output is TOON: one tabular block per section. After the data, `archive_height`
+ `next_block` print to stderr so stdout stays clean. A pagination hint shows
the next `envio data` invocation to call.

## Common recipes

### EVM — find when a contract started emitting an event

```bash
envio data block.number log.transactionHash \
  --chain=base \
  --where='{
    block: { number: { _gte: 0 } },
    log: {
      srcAddress: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
      topic0: "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
    },
  }'
```

The first row is the earliest matching block. Use `block.number._gte: <next_block>` from the printed hint to page forward; pick a tight range (50–200 blocks) for fast, deterministic tests.

### EVM — current archive height (no `/query` call)

```bash
envio data knownHeight --chain=arbitrum-one
```

Hits the height endpoint directly. Useful for picking a recent block range.

### Fuel mainnet — receipts from a specific contract

```bash
envio data block.height receipt.contractId receipt.receiptIndex receipt.txId \
  --chain=fuel \
  --where='{
    block: { height: { _gte: 0 } },
    receipt: { contractId: "0xf8134f388..." },
  }'
```

### Fuel testnet — height only

```bash
envio data knownHeight --chain=fuel-testnet
```

## Filter operators

| Form                              | Meaning                                       |
| --------------------------------- | --------------------------------------------- |
| `srcAddress: "0xabc"`             | `_eq` shortcut                                |
| `srcAddress: ["0xa", "0xb"]`      | `_in` shortcut                                |
| `srcAddress: { _eq: "0xa" }`      | explicit equality                             |
| `srcAddress: { _in: ["0xa"] }`    | explicit set membership                       |
| `block.number._gte: 1000`         | inclusive lower bound → `from_block`          |
| `block.number._lte: 2000`         | inclusive upper bound                         |
| `block.number._gt: 999`           | exclusive lower bound                         |
| `block.number._lt: 2001`          | exclusive upper bound                         |

## Tips

- Pipe stdout to `head`, `grep`, etc. — the pagination hint is on stderr.
- Run `envio data --help` for the full positional/flag list.
- `knownHeight` mixed with other fields appends an `archiveHeight` block to
  the output; alone, it skips `/query` and hits the height endpoint instead.
