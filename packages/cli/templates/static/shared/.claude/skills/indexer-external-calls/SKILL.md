---
name: indexer-external-calls
description: >-
  Use when making RPC calls, fetch requests, or any external I/O from handlers.
  Effect API with createEffect, S schema validation, context.effect(), preload
  optimization (handlers run twice), cache and rateLimit options.
metadata:
  managed-by: envio
---

# External Calls (Effect API)

Handlers run twice: parallel **preload pass** (warms caches), then **sequential pass** (state changes). All external I/O (fetch, RPC, APIs) MUST go through `createEffect` + `context.effect()` — otherwise it double-executes and blocks parallelization.

## Define and call

```ts
import { S, createEffect } from "envio";

const getOwner = createEffect(
  {
    name: "getOwner",
    input: { tokenId: S.bigint },
    output: S.union([S.string, null]),
    cache: true,
    rateLimit: false,
  },
  async ({ input }) => {
    const res = await fetch(`https://api.example.com/owner/${input.tokenId}`);
    return res.json();
  }
);

indexer.onEvent(
  { contract: "Token", event: "Transfer" },
  async ({ event, context }) => {
    const owner = await context.effect(getOwner, { tokenId: event.params.tokenId });
  }
);
```

## Pass minimum input

`input` carries only what varies per call. Bake static config (URLs, tokens, channel IDs, env vars) into the effect body. Build payloads/strings inside the effect.

```ts
// ❌ input: { url, chatId, text }   — config and pre-built strings leak into the call site
// ✅ input: { usd, blockNumber }    — only the values that vary per call
```

Dedup is keyed by hash of `input`; leaner inputs dedupe better, validate faster, and let one effect serve many call sites.

## Schema (`S`)

`S.string`, `S.number`, `S.bigint`, `S.boolean`, `S.schema({ ... })`, `S.array(...)`, `S.union([..., null])`, `S.optional(...)`.
Full ref: https://raw.githubusercontent.com/DZakh/sury/refs/tags/v9.3.0/docs/js-usage.md

## RPC pattern (viem)

```ts
const client = createPublicClient({ transport: http(process.env.ENVIO_RPC_URL) });

const getTokenMetadata = createEffect(
  {
    name: "getTokenMetadata",
    input: S.string,
    output: { name: S.string, symbol: S.string, decimals: S.number },
    cache: true,
    rateLimit: false,
  },
  async ({ input: address }) => {
    const args = { address: address as `0x${string}`, abi: ERC20_ABI };
    const [name, symbol, decimals] = await Promise.all([
      client.readContract({ ...args, functionName: "name" }),
      client.readContract({ ...args, functionName: "symbol" }),
      client.readContract({ ...args, functionName: "decimals" }),
    ]);
    return { name, symbol, decimals: Number(decimals) };
  }
);
```

## Options

| Option | Type | Default |
|---|---|---|
| `name` | `string` | — |
| `input` | `S.Schema` | — |
| `output` | `S.Schema` | — |
| `cache` | `boolean` | `false` |
| `rateLimit` | `false \| { calls, per }` | required |
| `crossChain` | `boolean` | `true` |

## crossChain (per-chain caching)

`crossChain` decides whether an input is cached and rate-limited once globally or once per chain. Default `true`.

- **`crossChain: true` (default):** one shared cache. Use for chain-agnostic calls — the result is the same whatever chain asked (token metadata, a price by symbol).
- **`crossChain: false`:** a separate cache and rate-limit budget per chain, and `context.chain.id` becomes available in the handler. Use when the result depends on the chain — an on-chain read, a per-chain RPC. The same input is fetched once per chain instead of once globally.

```ts
// Result depends on the chain -> crossChain: false, read context.chain.id
const getBalance = createEffect(
  { name: "getBalance", input: S.string, output: S.bigint, rateLimit: false, crossChain: false },
  async ({ input: account, context }) => rpcFor(context.chain.id).getBalance(account)
);
```

A cross-chain effect can only call other cross-chain effects (it has no single chain to resolve a chain-scoped call against); a chain-scoped effect can call either. Reading `context.chain` on a cross-chain effect throws. Changing an effect's `crossChain` or `name` starts a fresh cache.

> If something is unclear, use the `envio-docs` skill to search and read the latest documentation.
