---
name: indexing-filters
description: >-
  Use when filtering events by indexed parameters to reduce processing volume.
  eventFilters with static arrays, dynamic per-chain functions, contract
  address filtering, and conditional enable/disable.
---

# Event Filters

The `eventFilters` handler option filters events by indexed parameters. Works with or without `wildcard: true`.

## Array Form — Static Filters

```ts
ERC20.Transfer.handler(
  async ({ event, context }) => { /* ... */ },
  {
    wildcard: true,
    eventFilters: [{ from: ZERO_ADDRESS }, { to: ZERO_ADDRESS }],
  }
);
```

Each filter object is **OR'd** together. Within a filter, fields are **AND'd**. Arrays in a field position match **any** value in the array.

## Single Object Form

```ts
ERC20.Transfer.handler(
  async ({ event, context }) => { /* ... */ },
  {
    wildcard: true,
    eventFilters: { from: ZERO_ADDRESS, to: WHITELISTED },
  }
);
```

## Function Form — Dynamic Per-Chain

Return filters based on `chainId`. Return `false` to skip the chain entirely, `[]` to skip all events, `true` to allow all:

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

## Function with `addresses` — Filter by Registered Contracts

For dynamically registered contracts, use `addresses` to filter by their addresses:

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

## Filter Semantics

- Filter fields correspond to the event's **indexed parameters** only
- Multiple filter objects → OR (match any)
- Multiple fields in one object → AND (match all)
- Array value in a field → match any value in the array
- `return false` → disable handler for that chain
- `return true` → process all events (no filtering)
- `return []` → skip all events

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
