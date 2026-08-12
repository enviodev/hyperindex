---
name: indexer-transactions
description: >-
  Use when needing transaction-level data in handlers. Configure field_selection
  to include transaction fields on events, and access via event.transaction.
  No native transaction handler — access through event handlers.
metadata:
  managed-by: envio
---

# Transaction Data

The Envio Indexer does not have a native transaction handler (`onTransaction`). Transaction data is accessed through event handlers via `field_selection` in config.yaml.

## Configuring Transaction Fields

By default, `event.transaction` is empty. Select needed fields explicitly:

```yaml
contracts:
  - name: MyContract
    events:
      - event: Transfer(indexed address from, indexed address to, uint256 value)
        field_selection:
          transaction_fields:
            - hash
            - from
            - to
            - gasUsed
            - value
```

Or globally for all events:

```yaml
field_selection:
  transaction_fields:
    - hash
    - from
    - to
```

## Accessing in Handlers

```ts
indexer.onEvent({ contract: "MyContract", event: "Transfer" }, async ({ event, context }) => {
  const txHash = event.transaction.hash;
  const txFrom = event.transaction.from;
  const gasUsed = event.transaction.gasUsed;
});
```

## Selecting Fields in the Handler

`fields` names a registration's block and transaction fields inline, **replacing**
`field_selection` for that registration — including fields config.yaml selected
but this list omits. `block.number` is always readable; everything else has to be
listed. EVM only, on `indexer.onEvent` and `indexer.contractRegister`.

```ts
indexer.onEvent(
  {
    contract: "MyContract",
    event: "Transfer",
    fields: { transaction: ["hash", "from"], block: ["timestamp"] },
  },
  async ({ event, context }) => {
    const hash = event.transaction.hash; // string
    const gas: bigint = event.transaction.gasUsed; // Type error: not selected
  },
);
```

Write the selection inline, or in a variable declared `as const` — a variable
typed `EvmFieldsSelection` is rejected, because it no longer says which fields
this registration picked.

Two handlers on one event can select different sets. Read only what you listed:
anything else is a type error, and its value is not guaranteed.

## Available Transaction Fields

`transactionIndex`, `hash`, `from`, `to`, `gas`, `gasPrice`, `maxPriorityFeePerGas`, `maxFeePerGas`, `cumulativeGasUsed`, `effectiveGasPrice`, `gasUsed`, `input`, `nonce`, `value`, `v`, `r`, `s`, `contractAddress`, `logsBloom`, `root`, `status`, `yParity`, `accessList`, `maxFeePerBlobGas`, `blobVersionedHashes`, `type`, `l1Fee`, `l1GasPrice`, `l1GasUsed`, `l1FeeScalar`, `gasUsedForL1`, `authorizationList`

## Available Block Fields

Block fields are also configurable via `block_fields`. Default: `number`, `timestamp`, `hash`.

Additional: `parentHash`, `nonce`, `sha3Uncles`, `logsBloom`, `transactionsRoot`, `stateRoot`, `receiptsRoot`, `miner`, `difficulty`, `totalDifficulty`, `extraData`, `size`, `gasLimit`, `gasUsed`, `uncles`, `baseFeePerGas`, `blobGasUsed`, `excessBlobGas`, `parentBeaconBlockRoot`, `withdrawalsRoot`, `l1BlockNumber`, `sendCount`, `sendRoot`, `mixHash`

> If something is unclear, use the `envio-docs` skill to search and read the latest documentation.
