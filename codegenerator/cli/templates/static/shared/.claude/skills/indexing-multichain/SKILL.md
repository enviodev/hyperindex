---
name: indexing-multichain
description: >-
  Use when deploying an indexer across multiple chains. Entity ID namespacing
  to avoid collisions, chain-specific configuration patterns, and the
  context.chain runtime API.
---

# Multichain Indexing

## Entity ID Namespacing

Always prefix entity IDs with `chainId` to avoid collisions across chains:

```ts
const id = `${event.chainId}-${event.params.tokenId}`;
context.Token.set({ id, ...tokenData });
```

Never hardcode `chainId = 1` — always use `event.chainId`.

Chain-specific singleton IDs (e.g., Bundle): `${event.chainId}-1`

## Chain-Specific Logic

```ts
Contract.Event.handler(async ({ event, context }) => {
  const chainId = context.chain.id;

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

## Config

Global contract definitions + chain-specific addresses:

```yaml
contracts:
  - name: ERC20
    events:
      - event: Transfer(indexed address from, indexed address to, uint256 value)

chains:
  - id: 1
    contracts:
      - name: ERC20
        address:
          - 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
  - id: 137
    contracts:
      - name: ERC20
        address:
          - 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174
```

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
