---
name: indexer-transactions
description: >-
  Use when needing transaction- or block-level data in handlers. Select the
  fields a handler reads with the `fields` option, and access via
  event.transaction / event.block. No native transaction handler — access
  through event handlers.
metadata:
  managed-by: envio
---

# Transaction and Block Data

There is no native transaction handler (`onTransaction`). Transaction and block
data reach handlers through `event.transaction` / `event.block`, and both carry
only the fields that handler selected.

## Selecting Fields

Name them in the handler's `fields` option — the recommended way, on
`indexer.onEvent` and `indexer.contractRegister`:

```ts
indexer.onEvent(
  {
    contract: "MyContract",
    event: "Transfer",
    fields: { transaction: ["hash", "from"], block: ["timestamp"] },
  },
  async ({ event, context }) => {
    event.transaction.hash; // string
    event.block.timestamp; // number
    event.transaction.gasUsed; // Type error: not selected
  },
);
```

Reading a field you didn't list is a compile error, so the selection and the
handler can't drift. `block.number` is always readable; everything else has to
be listed.

Two handlers on one event can select different sets. Read only what you listed —
anything else is a type error, and its value is not guaranteed.

Write the selection inline, or in a variable declared `as const`. A variable
typed `EvmFieldsSelection` is rejected, because it no longer says which fields
this registration picked.

## Selecting Fields in config.yaml

`field_selection` selects fields for every handler of an event (or, at the root
level, of every event). Prefer the `fields` option above: it keeps the selection
next to the code that reads it, and lets two handlers on one event differ.

```yaml
field_selection:
  transaction_fields: [hash, from]
  block_fields: [timestamp]
```

A handler's `fields` **replaces** `field_selection` for that registration —
including fields config.yaml selected but the list omits.

## Available Transaction Fields

`transactionIndex`, `hash`, `from`, `to`, `gas`, `gasPrice`, `maxPriorityFeePerGas`, `maxFeePerGas`, `cumulativeGasUsed`, `effectiveGasPrice`, `gasUsed`, `input`, `nonce`, `value`, `v`, `r`, `s`, `contractAddress`, `logsBloom`, `root`, `status`, `yParity`, `accessList`, `maxFeePerBlobGas`, `blobVersionedHashes`, `type`, `l1Fee`, `l1GasPrice`, `l1GasUsed`, `l1FeeScalar`, `gasUsedForL1`, `authorizationList`

## Available Block Fields

Always readable: `number`. Selectable: `timestamp`, `hash`, `parentHash`, `nonce`, `sha3Uncles`, `logsBloom`, `transactionsRoot`, `stateRoot`, `receiptsRoot`, `miner`, `difficulty`, `totalDifficulty`, `extraData`, `size`, `gasLimit`, `gasUsed`, `uncles`, `baseFeePerGas`, `blobGasUsed`, `excessBlobGas`, `parentBeaconBlockRoot`, `withdrawalsRoot`, `l1BlockNumber`, `sendCount`, `sendRoot`, `mixHash`

> If something is unclear, use the `envio-docs` skill to search and read the latest documentation.
