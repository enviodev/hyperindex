---
name: indexer-transactions
description: >-
  Use when a handler needs transaction or block data — event.transaction /
  event.block, and the `fields` option that selects what they carry. There is no
  onTransaction handler; transaction data arrives through event handlers.
metadata:
  managed-by: envio
---

# Transaction and Block Data

There is no `onTransaction` handler. Transaction and block data reach a handler
through `event.transaction` and `event.block`.

They carry only the fields the handler asks for. List them in `fields`:

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
    event.transaction.gasUsed; // Type error: not listed in fields
  },
);
```

Reading a field you didn't list is a type error. `event.block.number` is
available without listing it.

Available on `indexer.onEvent` and `indexer.contractRegister`. Two handlers on
the same event can list different fields.

Write the list inline, as above. To reuse one, declare it `as const`:

```ts
const txFields = { transaction: ["hash", "from"] } as const;

indexer.onEvent({ contract: "MyContract", event: "Transfer", fields: txFields }, handler);
```

## Selecting in config.yaml instead

`field_selection` applies to every handler of an event, or of every event when
placed at the root level. Prefer `fields` in the handler — the list sits next to
the code that reads it. A handler's `fields` overrides `field_selection`.

```yaml
field_selection:
  transaction_fields: [hash, from]
  block_fields: [timestamp]
```

## Available Transaction Fields

`transactionIndex`, `hash`, `from`, `to`, `gas`, `gasPrice`, `maxPriorityFeePerGas`, `maxFeePerGas`, `cumulativeGasUsed`, `effectiveGasPrice`, `gasUsed`, `input`, `nonce`, `value`, `v`, `r`, `s`, `contractAddress`, `logsBloom`, `root`, `status`, `yParity`, `accessList`, `maxFeePerBlobGas`, `blobVersionedHashes`, `type`, `l1Fee`, `l1GasPrice`, `l1GasUsed`, `l1FeeScalar`, `gasUsedForL1`, `authorizationList`

Some are chain-specific and read as `undefined` where they don't apply: the
`l1*` fields need an L2, `root` only appears on pre-Byzantium transactions.

## Available Block Fields

`event.block.number` is always available. The rest must be listed:

`timestamp`, `hash`, `parentHash`, `nonce`, `sha3Uncles`, `logsBloom`, `transactionsRoot`, `stateRoot`, `receiptsRoot`, `miner`, `difficulty`, `totalDifficulty`, `extraData`, `size`, `gasLimit`, `gasUsed`, `uncles`, `baseFeePerGas`, `blobGasUsed`, `excessBlobGas`, `parentBeaconBlockRoot`, `withdrawalsRoot`, `l1BlockNumber`, `sendCount`, `sendRoot`, `mixHash`

> If something is unclear, use the `envio-docs` skill to search and read the latest documentation.
