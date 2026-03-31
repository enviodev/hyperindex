---
name: indexing-factory
description: >-
  Use when indexing contracts deployed by factory contracts at runtime.
  contractRegister API, dynamic contract config (no address), async
  registration, and same-block event coverage.
---

# Factory / Dynamic Contracts

For contracts created at runtime by factory contracts (e.g., Uniswap Pair creation).

## Config

Dynamic contracts have no address — they're registered by `contractRegister`:

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

## contractRegister

Must be defined BEFORE the handler. Registers new contract addresses for indexing:

```ts
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

The `context.add<ContractName>()` methods are auto-generated based on contracts in config that have no address.

## Async Contract Register

Perform external calls to decide which contract to register:

```ts
NftFactory.SimpleNftCreated.contractRegister(async ({ event, context }) => {
  const version = await getContractVersion(event.params.contractAddress);
  if (version === "v2") {
    context.addSimpleNftV2(event.params.contractAddress);
  } else {
    context.addSimpleNft(event.params.contractAddress);
  }
});
```

## Same-Block Coverage

When a dynamic contract is registered, HyperIndex indexes all events from that contract in the **same block** where it was created — even events from earlier transactions in that block.

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
