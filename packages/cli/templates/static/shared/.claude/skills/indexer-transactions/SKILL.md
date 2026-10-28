---
name: indexer-transactions
description: >-
  Use when a handler needs transaction or block data — event.transaction /
  event.block and the `fields` option that selects what they carry — or when the
  indexer must run on transactions themselves: indexer.onTransaction, filtered
  by sender, recipient, function selector or status.
metadata:
  managed-by: envio
---

# Transaction and Block Data

Two ways to reach transaction data: an event handler reads its own
transaction through `event.transaction`, and `indexer.onTransaction` runs a
handler on every transaction a filter matches, whether or not it emitted a log.

## indexer.onTransaction

Runs on the transactions of a chain that match `where`. No contract address or
`config.yaml` entry is needed; a transaction that emits no log on any indexed
contract still runs the handler, as does one that reverted.

```ts
import { indexer } from "envio";

indexer.onTransaction(
  {
    name: "TreasuryActivity",
    where: ({ chain }) =>
      chain.id === 1 && { transaction: { from: ["0x1234...abcd"] } },
    fields: { transaction: ["input", "value", "status"], block: ["timestamp"] },
  },
  async ({ transaction, block, context }) => {
    context.TreasuryTx.set({
      id: transaction.hash,
      to: transaction.to ?? "contract creation",
      value: transaction.value,
      reverted: transaction.status === 0,
      timestamp: block.timestamp,
    });
  },
);
```

### The `where` filter

`where` runs once per configured chain at registration time. Return `false` to
skip a chain, `true` to run on every transaction of the chain, or a filter:

```ts
{
  transaction: {
    from?: string[];      // senders
    to?: string[];        // recipients; a contract creation has none and never matches
    sighash?: string[];   // 4-byte function selectors the calldata starts with, e.g. "0xa9059cbb"
    status?: 0 | 1;       // 1 succeeded, 0 reverted; absent runs on both
  }
}
```

Fields are ANDed and the values within a field are ORed: `{ to: [A, B],
sighash: [S] }` matches a call of `S` on either `A` or `B`. A reverted
transaction is mined, so it runs the handler unless `status: 1` is given. A
filter naming no `from`, `to` or `sighash` runs on every transaction of the
chain, which the indexer warns about at startup: on a busy chain that is a
lot of transactions, and it is also what `where: ({ chain }) => chain.id === 1`
evaluates to when the filter object is forgotten.

Register several handlers for several wallets or selectors; a transaction
matching more than one runs each of them.

### Handler arguments

`transaction` always carries `transactionIndex`, `hash`, `from` and `to`, and
`block` always carries `number`, `timestamp` and `hash`. List anything else in
`fields`; reading a field you didn't list is a type error. The field names are
the ones listed under "Available Transaction Fields" and "Available Block
Fields" below. `context` is the same as an event handler's, and the handler
runs in the preload pass before the run proper, like an event handler
(`context.isPreload`).

### Ordering

Within a block, a transaction handler runs before the event handlers of the
same transaction and after those of the transactions before it, so an event
handler can read what the transaction handler wrote. Block handlers still run
last in their block.

### Sources

Over HyperSync the filter is applied server-side and only the matching
transactions are fetched. Over an RPC source there is no transaction filter in
JSON-RPC, so every block of the range is read in full (`eth_getBlockByNumber`
with transactions) and filtered client-side, with a receipt read only where a
`status` filter or a receipt-carried field (`status`, `gasUsed`, ...) needs it.
That is one request per block during a backfill, plus one per transaction a
`status` filter has to check (every transaction, for a filter naming no
`from`, `to` or `sighash`), so prefer HyperSync for historical ranges.

### Limits

- EVM only; registering on Fuel or Solana throws.
- Filter values are static. `to: chain.Contract.addresses` for dynamically
  registered contracts is not supported, and the filter takes no block range:
  a handler runs from the chain's `start_block`.
- A transaction handler cannot register contracts; that stays with
  `contractRegister`.
- `raw_events` rows are written for events only, not for transaction handler
  runs.

### Testing

`createTestIndexer` takes a simulated transaction beside simulated events. It
runs the handlers whose filter matches it, with the fields given:

```ts
await indexer.process({
  chains: {
    1: {
      startBlock: 0,
      endBlock: 10,
      simulate: [
        {
          transaction: { from: "0x1234...abcd", to: "0x...", input: "0xa9059cbb", value: 5n, status: 1 },
          block: { number: 3, timestamp: 1_700_000_003 },
        },
      ],
    },
  },
});
```

## Reading transaction data in an event handler

`event.transaction` and `event.block` carry only the fields the handler asks
for. List them in `fields`:

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
