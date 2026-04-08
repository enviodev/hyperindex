---
name: indexing-filters
description: >-
  Use when filtering events by indexed parameters to reduce processing volume.
  The `where` option supports static filters, dynamic per-chain functions,
  contract address filtering, and conditional enable/disable.
---

# Event Filters (`where`)

The `where` handler option filters events by indexed parameters. Works with or without `wildcard: true`.

The filter record is nested under a `params` field so future filter dimensions (block, transaction, …) can be added as siblings.

## Array Form — Static Filters (OR)

```ts
indexer.onEvent(
  { contract: "ERC20", event: "Transfer", wildcard: true,
    where: [
      { params: { from: ZERO_ADDRESS } },
      { params: { to: ZERO_ADDRESS } },
    ] },
  async ({ event, context }) => { /* ... */ },
);
```

Each entry in the array is **OR'd** together. Within a single `params` record, fields are **AND'd**. Arrays in a field position match **any** value in the array.

## Single Object Form

```ts
indexer.onEvent(
  { contract: "ERC20", event: "Transfer", wildcard: true,
    where: { params: { from: ZERO_ADDRESS, to: WHITELISTED } } },
  async ({ event, context }) => { /* ... */ },
);
```

## Function Form — Dynamic Per-Chain

Return a filter based on `chainId`. Return `false` to skip the chain entirely (no events processed), or `true` (or `[]`) to allow all events. To filter, return a single `where` condition or an array of conditions:

```ts
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const WHITELISTED = {
  137: ["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as const],
  100: ["0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC" as const],
};

indexer.onEvent(
  { contract: "ERC20", event: "Transfer", wildcard: true,
    where: ({ chainId }) => {
      if (chainId !== 100 && chainId !== 137) return false;
      return [
        { params: { from: ZERO_ADDRESS, to: WHITELISTED[chainId] } },
        { params: { from: WHITELISTED[chainId], to: ZERO_ADDRESS } },
      ];
    } },
  async ({ event, context }) => { /* ... */ },
);
```

## Function with `addresses` — Filter by Registered Contracts

For dynamically registered contracts, use `addresses` to filter by their addresses:

```ts
indexer.onEvent(
  { contract: "ERC20", event: "Transfer", wildcard: true,
    where: ({ chainId, addresses }) => {
      if (chainId !== 100 && chainId !== 137) return false;
      return [
        { params: { from: ZERO_ADDRESS, to: addresses } },
        { params: { from: addresses, to: ZERO_ADDRESS } },
      ];
    } },
  async ({ event, context }) => { /* ... */ },
);
```

## Filter Semantics

- Filter fields under `params` correspond to the event's **indexed parameters** only
- Multiple filter objects → OR (match any)
- Multiple fields in one `params` record → AND (match all)
- Array value in a field → match any value in the array
- `return false` → skip the chain entirely (no events processed for that chain)
- `return true` (or `[]`) → accept all events (no filtering, default topic0-only selection)

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
