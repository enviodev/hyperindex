---
name: indexing-traces
description: >-
  Use when needing call trace data from transactions. HyperSync supports trace
  queries at the data layer. No handler-level trace API currently — access
  traces via HyperSync client directly.
---

# Trace Indexing

## Current Status

HyperSync supports full trace queries at the data layer, but HyperIndex does not yet expose a handler-level trace API (like `onTrace`).

## HyperSync Trace Support

HyperSync can query traces with filtering by:
- `from` / `to` — sender/recipient addresses
- `address` — contract address
- `callType` — call, delegatecall, staticcall
- `type` — call, create, suicide, reward
- `sighash` — function signatures

Available trace fields: `From`, `To`, `CallType`, `Gas`, `Input`, `Value`, `GasUsed`, `Output`, `Subtraces`, `TraceAddress`, `TransactionHash`, `BlockNumber`, `Error`, and more.

## Workaround

For trace-dependent indexing, use the Effect API to fetch trace data from an RPC endpoint:

```ts
import { createEffect, S } from "envio";

const getTraces = createEffect(
  {
    name: "getTraces",
    input: S.schema({ blockNumber: S.number }),
    output: S.unknown,
    cache: true,
  },
  async ({ input }) => {
    const res = await fetch(RPC_URL, {
      method: "POST",
      body: JSON.stringify({
        jsonrpc: "2.0",
        method: "trace_block",
        params: [`0x${input.blockNumber.toString(16)}`],
        id: 1,
      }),
    });
    return (await res.json()).result;
  }
);
```

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
