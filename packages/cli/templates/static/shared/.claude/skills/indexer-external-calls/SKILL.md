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

## Cross-chain vs chain-scoped effects

`crossChain` controls whether an effect's cache (and rate-limit window) is shared across every chain or isolated per chain.

- **Omitted / `crossChain: true` (default):** one shared cache for the effect across all chains. The cache table is `envio_effect_<name>`, dumped to `.envio/cache/<name>.tsv`. `context.chain` is **not** available — reading it throws.
- **`crossChain: false`:** an isolated cache and an independent rate-limit window **per chain**. Each chain gets its own table `envio_<chainId>_effect_<name>`, dumped to `.envio/cache/<chainId>/<name>.tsv`. The handler can read `context.chain.id` (the chain the effect was called on). The same input on two chains is computed and cached separately; it only deduplicates within one chain.

```ts
// Chain-scoped: per-chain cache + rate limit, context.chain.id available.
const getBalance = createEffect(
  { name: "getBalance", input: S.string, output: S.bigint, rateLimit: false, crossChain: false },
  async ({ input: account, context }) => rpcFor(context.chain.id).getBalance(account)
);
```

Nesting rules: a handler may call either kind. A chain-scoped effect may call chain-scoped or cross-chain effects. A cross-chain effect may call other cross-chain effects, but calling a chain-scoped effect from a cross-chain effect throws (a cross-chain effect isn't tied to one chain, so there's no chain to resolve).

> Changing an effect's `crossChain` (or `name`) changes its cache identity — the old cache tables/files no longer apply.

> If something is unclear, use the `envio-docs` skill to search and read the latest documentation.
