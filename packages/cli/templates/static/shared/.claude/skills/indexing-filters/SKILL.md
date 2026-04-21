---
name: indexing-filters
description: >-
  Use when filtering events by indexed parameters to reduce processing volume.
  The `where` option supports static filters, dynamic per-chain functions,
  contract address filtering, and conditional enable/disable.
---

# Event Filters (`where`)

The `where` handler option filters events by indexed parameters and restricts the per-event block range. Works with or without `wildcard: true`.

The filter value is a `{ params?, block? }` record. `params` can be a **single object** (AND-conjunction across indexed parameters) or an **array** of objects (OR across multiple AND-conjunctions). `block.number._gte` (or `block.height._gte` on Fuel) promotes to the event's **startBlock** and overrides the contract-level `start_block` from `config.yaml`.

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
      return {
        params: [
          { from: ZERO_ADDRESS, to: chain.ERC20.addresses },
          { from: chain.ERC20.addresses, to: ZERO_ADDRESS },
        ],
      };
    },
  },
  async ({ event, context }) => {
    /* ... */
  },
);
```

## Per-Event `startBlock` via `block.number._gte`

Use `where.block` as a sibling of `params` to restrict an event to blocks at or after a given number. Overrides the contract's `start_block` from `config.yaml` — useful for narrowing a single event without touching the whole contract.

Use a `switch` on `chain.id` to pick the `startBlock` only, so the shared `params` filter isn't duplicated per chain. The `default: never` branch makes TypeScript flag any chain added to `config.yaml` but not handled here:

```ts
indexer.onEvent(
  {
    contract: "ERC20",
    event: "Transfer",
    wildcard: true,
    where: ({ chain }) => {
      let startBlock: number;
      switch (chain.id) {
        case 1:
          startBlock = 18000000;
          break;
        case 8453:
          startBlock = 2000000;
          break;
        default: {
          // Exhaustiveness check: TypeScript errors here if a new chain ID
          // is added to config.yaml but not handled above.
          const _exhaustive: never = chain.id;
          return false;
        }
      }
      return {
        block: { number: { _gte: startBlock } },
        params: [{ from: chain.ERC20.addresses }, { to: chain.ERC20.addresses }],
      };
    },
  },
  async ({ event, context }) => {
    /* ... */
  },
);
```

On Fuel, key the block range on `block.height` instead of `block.number`. SVM has no event handlers. Only `_gte` is accepted on event filters — for `_lte` or `_every` (stride), use `indexer.onBlock`. The `block` filter is only valid at the top level of `where`, not nested inside `params` array entries.

## Filter Semantics

- Filter fields inside each `params` entry correspond to the event's **indexed parameters** only
- Multiple entries in the `params` array → OR (match any)
- Multiple fields in one entry → AND (match all)
- Array value in a field → match any value in the array
- `block.number._gte` (EVM) / `block.height._gte` (Fuel) → per-event startBlock, overrides contract `start_block`
- `return false` → skip the chain entirely (no events processed for that chain)
- `return true` → accept all events (no filtering, default topic0-only selection)

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
