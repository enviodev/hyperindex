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

## Why Effects?

Envio Indexer uses **Preload Optimization** — handlers run TWICE:

1. **Preload pass**: all handlers in the batch run in parallel (to warm caches)
2. **Sequential pass**: handlers run in event order (actual state changes)

All external calls (fetch, RPC, APIs) MUST use the Effect API to prevent double execution and enable parallelization.

## Defining an Effect

```ts
import { S, createEffect } from "envio";

export const getSomething = createEffect(
  {
    name: "getSomething",
    input: {
      address: S.string,
      blockNumber: S.number,
    },
    output: S.union([S.string, null]),
    cache: true,
    rateLimit: false,
  },
  async ({ input, context }) => {
    const something = await fetch(
      `https://api.example.com/something?address=${input.address}&blockNumber=${input.blockNumber}`
    );
    return something.json();
  }
);
```

## Pass Minimum Input

Pass only the per-call data that varies between invocations. Bake static config (URLs, tokens, channel names, env-derived values) into the effect body. Construct strings, payloads, and templates inside the effect — not at the call site.

```ts
// ❌ Bloated input: static config and pre-built strings leak into the call site
export const notifyLargeSwap = createEffect(
  {
    name: "notifyLargeSwap",
    input: { url: S.string, chatId: S.string, text: S.string },
  },
  async ({ input }) => {
    await fetch(input.url, {
      method: "POST",
      body: JSON.stringify({ chat_id: input.chatId, text: input.text }),
    });
  }
);

// ✅ Minimum input: only the values that vary per call
export const notifyLargeSwap = createEffect(
  {
    name: "notifyLargeSwap",
    input: { usd: S.bigint, blockNumber: S.number },
  },
  async ({ input }) => {
    const text = `Large swap: $${input.usd.toLocaleString()} in block ${input.blockNumber}`;
    await fetch(`https://api.telegram.org/bot${process.env.ENVIO_TG_BOT_TOKEN}/sendMessage`, {
      method: "POST",
      body: JSON.stringify({ chat_id: process.env.ENVIO_TG_CHAT_ID, text }),
    });
  }
);
```

Why: within-batch dedup is keyed by hash of `input` — leaner inputs dedupe more reliably. Smaller schemas validate faster, logs stay readable, and the effect becomes reusable across handlers without each call site re-supplying the same config.

## Consuming in Handlers

```ts
import { getSomething } from "./utils";

Contract.Event.handler(async ({ event, context }) => {
  const something = await context.effect(getSomething, {
    address: event.srcAddress,
    blockNumber: event.block.number,
  });
  // Use the result...
});
```

## context.isPreload Guard

For non-effect side effects that should only run once:

```ts
Contract.Event.handler(async ({ event, context }) => {
  const data = await context.effect(myEffect, input);

  if (!context.isPreload) {
    console.log("Processing event", event.block.number);
  }
});
```

## S Schema Module

The `S` module exposes a schema creation API for input/output validation:
https://raw.githubusercontent.com/DZakh/sury/refs/tags/v9.3.0/docs/js-usage.md

Common schemas:
- `S.string`, `S.number`, `S.boolean`
- `S.schema({ field: S.string })`
- `S.array(S.string)`
- `S.union([S.string, null])`
- `S.optional(S.string)`

## RPC Call Pattern (viem)

```ts
import { createEffect, S } from "envio";
import { createPublicClient, http, parseAbi } from "viem";

const ERC20_ABI = parseAbi([
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
]);

const client = createPublicClient({
  transport: http(process.env.ENVIO_RPC_URL),
});

export const getTokenMetadata = createEffect(
  {
    name: "getTokenMetadata",
    input: S.string,
    output: S.schema({
      name: S.string,
      symbol: S.string,
      decimals: S.number,
    }),
    cache: true,
  },
  async ({ input: address }) => {
    const [name, symbol, decimals] = await Promise.all([
      client.readContract({ address: address as `0x${string}`, abi: ERC20_ABI, functionName: "name" }),
      client.readContract({ address: address as `0x${string}`, abi: ERC20_ABI, functionName: "symbol" }),
      client.readContract({ address: address as `0x${string}`, abi: ERC20_ABI, functionName: "decimals" }),
    ]);
    return { name, symbol, decimals: Number(decimals) };
  }
);
```

## Effect Options

| Option | Type | Description |
|--------|------|-------------|
| `name` | `string` | Name for debugging/logging |
| `input` | `S.Schema` | Input validation schema |
| `output` | `S.Schema` | Output validation schema |
| `cache` | `boolean` | Cache results for identical inputs (default: `false`) |
| `rateLimit` | `boolean \| { calls, per }` | Rate limit calls (default: `false`) |

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
