---
name: indexing-filters
description: >-
  Use when filtering events by indexed parameters to reduce processing volume.
  The `where` option supports static filters, dynamic per-chain functions,
  contract address filtering, and conditional enable/disable.
---

# Event Filters (`where`)

The `where` handler option filters events by indexed parameters. Works with or without `wildcard: true`.

The filter value is a `{ params: ... }` record. `params` can be a **single object** (AND-conjunction across indexed parameters) or an **array** of objects (OR across multiple AND-conjunctions). The `{params}` wrapper reserves room for future filter dimensions (block, transaction, …) as sibling fields.

## Single Object Form

```ts
indexer.onEvent(
  {
    contract: "ERC20",
    event: "Transfer",
    wildcard: true,
    where: { params: { from: ZERO_ADDRESS, to: WHITELISTED } },
  },
  async ({ event, context }) => {
    /* ... */
  },
);
```

## Array Form — Static Filters (OR)

```ts
indexer.onEvent(
  {
    contract: "ERC20",
    event: "Transfer",
    wildcard: true,
    where: {
      params: [{ from: ZERO_ADDRESS }, { to: ZERO_ADDRESS }],
    },
  },
  async ({ event, context }) => {
    /* ... */
  },
);
```

Each entry in the `params` array is **OR'd** together. Within a single entry, fields are **AND'd**. Arrays in a field position match **any** value in the array.

## Function Form — Dynamic Per-Chain

Return a filter based on the current `chain`. The callback receives `{ chain }` where `chain.id` is the chain ID and `chain.<ContractName>.addresses` exposes the indexed addresses of the event's own contract on that chain. Return `false` to skip the chain entirely (no events processed), or `true` to allow all events. To filter, return a `{params: ...}` object where `params` is a single record or an array of records:

```ts
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const WHITELISTED = {
  137: ["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as const],
  100: ["0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC" as const],
};

indexer.onEvent(
  {
    contract: "ERC20",
    event: "Transfer",
    wildcard: true,
    where: ({ chain }) => {
      if (chain.id !== 100 && chain.id !== 137) return false;
      return {
        params: [
          { from: ZERO_ADDRESS, to: WHITELISTED[chain.id] },
          { from: WHITELISTED[chain.id], to: ZERO_ADDRESS },
        ],
      };
    },
  },
  async ({ event, context }) => {
    /* ... */
  },
);
```

## Function with `chain.<Contract>.addresses` — Filter by Registered Contracts

For dynamically registered contracts, use `chain.<ContractName>.addresses` to filter by their addresses. Only the event's own contract is exposed:

```ts
indexer.onEvent(
  {
    contract: "ERC20",
    event: "Transfer",
    wildcard: true,
    where: ({ chain }) => {
      if (chain.id !== 100 && chain.id !== 137) return false;
      const addresses = chain.ERC20.addresses;
      return {
        params: [
          { from: ZERO_ADDRESS, to: addresses },
          { from: addresses, to: ZERO_ADDRESS },
        ],
      };
    },
  },
  async ({ event, context }) => {
    /* ... */
  },
);
```

## Filter Semantics

- Filter fields inside each `params` entry correspond to the event's **indexed parameters** only
- Multiple entries in the `params` array → OR (match any)
- Multiple fields in one entry → AND (match all)
- Array value in a field → match any value in the array
- `return false` → skip the chain entirely (no events processed for that chain)
- `return true` → accept all events (no filtering, default topic0-only selection)

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
