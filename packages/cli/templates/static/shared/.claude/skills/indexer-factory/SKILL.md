---
name: indexer-factory
description: >-
  Use when indexing contracts deployed by factory contracts at runtime.
  contractRegister API, dynamic contract config (no address), async
  registration, and same-block event coverage.
metadata:
  managed-by: envio
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

Register new contract addresses for indexing with `indexer.contractRegister`. The
event handler is a separate `indexer.onEvent` registration — order and file
placement between the two don't matter:

```ts
import { indexer, type Pair } from "envio";

indexer.contractRegister(
  { contract: "Factory", event: "PairCreated" },
  async ({ event, context }) => {
    context.chain.Pair.add(event.params.pair);
  },
);

indexer.onEvent(
  { contract: "Factory", event: "PairCreated" },
  async ({ event, context }) => {
    const pair: Pair = {
      id: `${event.chainId}-${event.params.pair}`,
      token0_id: `${event.chainId}-${event.params.token0}`,
      token1_id: `${event.chainId}-${event.params.token1}`,
    };
    context.Pair.set(pair);
  },
);
```

`context.chain.<ContractName>.add(address)` is available for every contract
in config that has no address. The `<ContractName>` matches the contract `name`
in `config.yaml`.

## Async Contract Register

Perform external calls to decide which contract to register:

```ts
indexer.contractRegister(
  { contract: "NftFactory", event: "SimpleNftCreated" },
  async ({ event, context }) => {
    const version = await getContractVersion(event.params.contractAddress);
    if (version === "v2") {
      context.chain.SimpleNftV2.add(event.params.contractAddress);
    } else {
      context.chain.SimpleNft.add(event.params.contractAddress);
    }
  },
);
```

## Same-Block Coverage

When a dynamic contract is registered, the Envio Indexer indexes all events from that contract in the **same block** where it was created — even events from earlier transactions in that block.

> If something is unclear, use the `envio-docs` skill to search and read the latest documentation.
