---
name: indexer-transactions
description: >-
  Use when a handler needs transaction or block data, or must run on
  transactions themselves: indexer.onTransaction for every mined transaction a
  filter matches (wallet activity, calls to a contract, reverted calls), and
  the `fields` option that selects what event.transaction / event.block carry.
metadata:
  managed-by: envio
---

# Transactions and Block Data

## Transaction Handlers

`indexer.onTransaction` runs on every mined transaction its filter matches,
whether or not it emitted a log: a plain transfer from a wallet, a call to a
contract that logs nothing, a reverted call. No contract address or
`config.yaml` entry is needed beyond the chain itself.

```ts
import { indexer } from "envio";

indexer.onTransaction(
  {
    name: "TreasuryActivity",
    where: ({ chain }) => chain.id === 1 && { transaction: { from: ["0x1111111111111111111111111111111111111111"] } },
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

`where` is required and runs once per configured chain at registration. Return
`false` to skip the chain, `true` to run on every transaction, or a filter:

```ts
{
  transaction: {
    from?: string[];     // senders
    to?: string[];       // recipients; a contract creation has none and never matches
    status?: 0 | 1;      // 1 succeeded, 0 reverted; absent runs on both
  }
}
```

- Fields are ANDed, values within a field are ORed: `{ from: [S], to: [A, B] }`
  matches a transaction `S` sends to `A` or `B`.
- To run on calls of one function, filter on `to` and check the calldata's
  selector in the handler (`transaction.input.startsWith("0xa9059cbb")`, with
  `input` in `fields`). A call made inside another contract's call is not a
  transaction: use the event it emits instead.
- Reverted transactions are mined, so they run the handler unless `status: 1`
  is given. Blocks from before Byzantium carry no status: a `status` filter
  matches none of their transactions.
- A filter naming no `from` or `to` runs on every transaction of the
  chain. It is allowed, and warned about at startup.
- An address that isn't 20 bytes, an empty list or a
  `status` other than 0 or 1 throws at registration.
- Several handlers may match one transaction: each runs, in registration order.

What the handler gets:

- `transaction` always carries `transactionIndex`, `hash`, `from` and `to`;
  `block` always carries `number`, `timestamp` and `hash`. Anything else is
  listed in `fields`, with the names below. Reading an unlisted field is a type
  error.
- `context` is an event handler's: entities, effects, `log`, `chain.id`,
  `isPreload`. The handler runs in the preload pass too.
- A transaction's handlers run before the event handlers of that transaction
  and after the events of earlier ones. Block handlers run last in the block.

Fetching: HyperSync filters on the server. RPC has no transaction filter, so it
reads every block in full (100 blocks per request page) and filters locally,
reading a receipt only where a `status` filter or a receipt field (`status`,
`gasUsed`, `effectiveGasPrice`, ...) needs one. Over RPC, a filter naming no
`from` or `to` costs every block in full, and a receipt per
transaction if it filters on `status`.

Limits: EVM only. Filter values are static: `chain.<Contract>.addresses` can't
be used, list the addresses. No block range: a handler runs from the chain's
`start_block`. A transaction handler can't register contracts. `raw_events`
rows are written for events only.

Testing: simulate a transaction as `{ transaction: {...}, block: {...} }`. Only
the fields given are set, so a filter on a field left out doesn't match.
`transactionIndex` defaults to the block's next free index and `hash` to one
made from the block number and that index; an event's
`transaction.transactionIndex` (0 by default) places it among them.

```ts
await indexer.process({
  chains: {
    1: {
      startBlock: 0,
      endBlock: 10,
      simulate: [
        {
          transaction: { from: "0x1111111111111111111111111111111111111111", to: "0xdAC17F958D2ee523a2206206994597C13D831ec7", input: "0xa9059cbb", value: 5n, status: 1 },
          block: { number: 3, timestamp: 1_700_000_003 },
        },
      ],
    },
  },
});
```

## Transaction and Block Data on Events

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

Available on `indexer.onEvent`, `indexer.contractRegister` and
`indexer.onTransaction`. Two handlers on the same event can list different
fields.

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
