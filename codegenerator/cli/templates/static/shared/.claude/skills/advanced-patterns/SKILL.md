---
name: advanced-patterns
description: >-
  Advanced HyperIndex patterns: multichain indexing (entity ID namespacing,
  ordered vs unordered mode), dynamic contracts (contractRegister, factory
  patterns), wildcard indexing, block handlers, and database indexes (@index
  with DESC). Use for multi-chain setups, factory contracts, or block-level
  processing.
---

# Advanced HyperIndex Patterns

## Multichain Indexing

### Entity ID Namespacing

Always prefix entity IDs with `chainId` to avoid collisions across chains:

```ts
const id = `${event.chainId}-${event.params.tokenId}`;
context.Token.set({ id, ...tokenData });
```

Never hardcode `chainId = 1` — always use `event.chainId`.

Chain-specific singleton IDs (e.g., Bundle): `${event.chainId}-1`

### Multichain Mode

Configure in `config.yaml`:

```yaml
multichain: ordered    # Events ordered globally across chains (slower, deterministic)
# or
multichain: unordered  # Events processed per-chain independently (faster, default)
```

- **`unordered`** (default): Each chain processes independently. Faster but no cross-chain ordering guarantees.
- **`ordered`**: Events from all chains are globally ordered by block timestamp. Slower but deterministic cross-chain behavior.

### Chain-Specific Logic

```ts
Contract.Event.handler(async ({ event, context }) => {
  const chainId = context.chain.id;

  // Chain-specific configuration
  const config = {
    1: { wrappedNative: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2" },
    137: { wrappedNative: "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270" },
  }[chainId];

  // context.chain.isLive is true when processing real-time blocks
  if (context.chain.isLive) {
    // Live-only logic
  }
});
```

## Dynamic Contracts (Factory Pattern)

For contracts created at runtime by factory contracts (e.g., Uniswap Pair creation):

### Config

```yaml
contracts:
  - name: Factory
    events:
      - event: PairCreated(indexed address token0, indexed address token1, address pair, uint256)
  - name: Pair
    # No address — registered dynamically
    events:
      - event: Swap(indexed address sender, uint256 amount0In, ...)
      - event: Sync(uint112 reserve0, uint112 reserve1)

chains:
  - id: 1
    contracts:
      - name: Factory
        address:
          - 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f
      - name: Pair
        # No address here — will be registered by contractRegister
```

### Handler

```ts
// contractRegister MUST be defined BEFORE the handler
Factory.PairCreated.contractRegister(({ event, context }) => {
  context.addPair(event.params.pair);
});

Factory.PairCreated.handler(async ({ event, context }) => {
  const pair: Pair = {
    id: `${event.chainId}-${event.params.pair}`,
    token0_id: `${event.chainId}-${event.params.token0}`,
    token1_id: `${event.chainId}-${event.params.token1}`,
  };
  context.Pair.set(pair);
});
```

## Wildcard Indexing

Index all instances of a contract across all addresses (e.g., all ERC-20 transfers).

### Config (no address = wildcard)

```yaml
contracts:
  - name: ERC20
    events:
      - event: Transfer(indexed address from, indexed address to, uint256 value)

chains:
  - id: 1
    contracts:
      - name: ERC20
        # No address = wildcard (indexes ALL matching events on the chain)
```

### Handler with `wildcard: true` option

Use `event.srcAddress` to identify which contract emitted the event. Pass `wildcard: true` as the handler's 2nd argument:

```ts
ERC20.Transfer.handler(
  async ({ event, context }) => {
    const tokenAddress = event.srcAddress; // The actual contract address
    const id = `${event.chainId}-${event.transaction.hash}-${event.logIndex}`;

    context.Transfer.set({
      id,
      token_id: `${event.chainId}-${tokenAddress}`,
      from: event.params.from,
      to: event.params.to,
      value: event.params.value,
    });
  },
  { wildcard: true }
);
```

### Event Filters

The `eventFilters` handler option filters wildcard events by indexed parameters. Three forms:

**Array form** — static filter objects:

```ts
ERC20.Transfer.handler(
  async ({ event, context }) => { /* ... */ },
  {
    wildcard: true,
    eventFilters: [{ from: ZERO_ADDRESS }, { to: ZERO_ADDRESS }],
  }
);
```

**Function form** — dynamic per-chain filters (return `false` to skip chain, `[]` to skip all events):

```ts
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const WHITELISTED = {
  137: ["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as const],
  100: ["0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC" as const],
};

ERC20.Transfer.handler(
  async ({ event, context }) => { /* ... */ },
  {
    wildcard: true,
    eventFilters: ({ chainId }) => {
      if (chainId !== 100 && chainId !== 137) return false;
      return [
        { from: ZERO_ADDRESS, to: WHITELISTED[chainId] },
        { from: WHITELISTED[chainId], to: ZERO_ADDRESS },
      ];
    },
  }
);
```

**Function with `addresses`** — filter using the contract's registered addresses:

```ts
ERC20.Transfer.handler(
  async ({ event, context }) => { /* ... */ },
  {
    wildcard: true,
    eventFilters: ({ chainId, addresses }) => {
      if (chainId !== 100 && chainId !== 137) return false;
      return [
        { from: ZERO_ADDRESS, to: addresses },
        { from: addresses, to: ZERO_ADDRESS },
      ];
    },
  }
);
```

Filter fields correspond to the event's indexed parameters. Each filter object is OR'd together; within a filter, fields are AND'd. Arrays in a field position match any value in the array.

## Block Handlers

Process every block (or every Nth block). No contract address needed — uses `onBlock` from `generated`.

### Handler

```ts
import { onBlock } from "generated";

onBlock(
  { name: "BlockTracker", chain: 1, interval: 100 },
  async ({ block, context }) => {
    context.BlockSnapshot.set({
      id: `${block.number}`,
      blockNumber: BigInt(block.number),
      timestamp: BigInt(block.timestamp),
    });
  }
);
```

Options: `name` (required), `chain` (chain ID), `interval` (process every Nth block, default 1), `startBlock`, `endBlock`.

No config.yaml entry needed — `onBlock` self-registers. No events or address required.

## Database Indexes

Add `@index` directives to schema fields for faster queries:

### Basic Index

```graphql
type Transfer {
  id: ID!
  from: String! @index
  to: String! @index
  value: BigInt!
  timestamp: BigInt!
}
```

### Composite Index with DESC

```graphql
type Trade {
  id: ID!
  poolId: String!
  date: BigInt!
  volume: BigDecimal!
}

# Index for querying trades by pool, ordered by date descending
# @index(fields: ["poolId", ["date", "DESC"]])
```

Syntax: `@index(fields: ["field1", ["field2", "DESC"]])`

- Fields without direction default to ASC
- Use DESC for time-ordered queries (most recent first)
- Composite indexes speed up queries that filter/sort by multiple fields

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
