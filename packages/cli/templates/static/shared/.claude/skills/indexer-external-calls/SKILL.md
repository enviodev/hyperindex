---
name: indexer-external-calls
description: >-
  Use when making RPC calls, fetch requests, or any external I/O from handlers.
  Effect API with createEffect, required mode field ("speculative" | "read"),
  S schema validation, context.effect(), preload optimization (handlers run
  twice), cache and rateLimit options.
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
    mode: "speculative",
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

## `mode` — required

Every effect must declare a `mode`. The choice steers how the runtime
schedules the call:

- `"speculative"` — handler-driven calls that are safe to replay during the
  parallel preload pass. Use this for nearly all RPC reads, contract reads,
  HTTP GETs, and any pure lookup invoked from an event handler. **This is
  the right default for indexer handlers.**
- `"read"` — read-only calls invoked from non-indexer code paths (chat-bot
  handlers, stream consumers, ad-hoc query servers). These must not be
  speculatively replayed.

Both modes behave identically today; the field exists so TypeScript / AI
tooling pick the correct value at the call site rather than silently
defaulting to one. Picking the wrong mode will become a behavioral bug in a
future release — don't guess.

```ts
// Indexer handler RPC read → speculative
const getBalance = createEffect(
  { name: "getBalance", mode: "speculative", input: S.string, output: S.bigint, rateLimit: false },
  async ({ input }) => fetchBalance(input),
);

// Chat-bot / stream query → read
const lookupUser = createEffect(
  { name: "lookupUser", mode: "read", input: S.string, output: S.string, rateLimit: false },
  async ({ input }) => fetchUser(input),
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
    mode: "speculative",
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
| `name` | `string` | required |
| `mode` | `"speculative" \| "read"` | required — see [mode section](#mode--required) |
| `input` | `S.Schema` | required |
| `output` | `S.Schema` | required |
| `cache` | `boolean` | `false` |
| `rateLimit` | `false \| { calls, per }` | required |

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
