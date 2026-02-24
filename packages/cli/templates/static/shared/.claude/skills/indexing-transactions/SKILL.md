---
name: indexing-transactions
description: >-
  Use when needing transaction-level data in handlers. Configure field_selection
  to include transaction fields on events, and access via event.transaction.
  No native transaction handler — access through event handlers.
---

# Transaction Data

HyperIndex does not have a native transaction handler (`onTransaction`). Transaction data is accessed through event handlers via `field_selection` in config.yaml.

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
Contract.Transfer.handler(async ({ event, context }) => {
  const txHash = event.transaction.hash;
  const txFrom = event.transaction.from;
  const gasUsed = event.transaction.gasUsed;
});
```

## Available Transaction Fields

`transactionIndex`, `hash`, `from`, `to`, `gas`, `gasPrice`, `maxPriorityFeePerGas`, `maxFeePerGas`, `cumulativeGasUsed`, `effectiveGasPrice`, `gasUsed`, `input`, `nonce`, `value`, `v`, `r`, `s`, `contractAddress`, `logsBloom`, `root`, `status`, `yParity`, `chainId`, `maxFeePerBlobGas`, `blobVersionedHashes`, `type`, `l1Fee`, `l1GasPrice`, `l1GasUsed`, `l1FeeScalar`, `gasUsedForL1`

## Available Block Fields

Block fields are also configurable via `block_fields`. Default: `number`, `timestamp`, `hash`.

Additional: `parentHash`, `nonce`, `sha3Uncles`, `logsBloom`, `transactionsRoot`, `stateRoot`, `receiptsRoot`, `miner`, `difficulty`, `totalDifficulty`, `extraData`, `size`, `gasLimit`, `gasUsed`, `uncles`, `baseFeePerGas`, `blobGasUsed`, `excessBlobGas`, `parentBeaconBlockRoot`, `withdrawalsRoot`, `l1BlockNumber`

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
