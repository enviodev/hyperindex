---
name: indexer-traces
description: >-
  Use when needing call trace data from transactions. HyperSync supports trace
  queries at the data layer. No handler-level trace API currently — access
  traces via HyperSync client directly.
metadata:
  managed-by: envio
---

# Trace Indexing

## Current Status

HyperSync supports full trace queries at the data layer, but the Envio Indexer does not yet expose a handler-level trace API (like `onTrace`).

## HyperSync Trace Support

HyperSync can query traces with filtering by (keys as in the HyperSync query JSON):
- `from` / `to` — sender/recipient addresses
- `address` — contract address
- `call_type` — call, delegatecall, staticcall
- `reward_type` — block reward type
- `type` — call, create, suicide, reward
- `sighash` — function signatures

Trace fields for `field_selection.trace`: `transaction_hash`, `block_hash`, `block_number`, `transaction_position`, `type`, `error`, `from`, `to`, `author`, `gas`, `gas_used`, `action_address`, `address`, `balance`, `call_type`, `code`, `init`, `input`, `output`, `refund_address`, `reward_type`, `sighash`, `subtraces`, `trace_address`, `value`.

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
    rateLimit: false,
  },
  async ({ input }) => {
    // Needs an RPC that supports trace_block (e.g. an archive node with the trace API)
    const res = await fetch(process.env.ENVIO_RPC_URL!, {
      method: "POST",
      body: JSON.stringify({
        jsonrpc: "2.0",
        method: "trace_block",
        params: [`0x${input.blockNumber.toString(16)}`],
        id: 1,
      }),
    });
    const { result } = (await res.json()) as { result: unknown };
    return result;
  }
);
```

> If something is unclear, use the `envio-docs` skill to search and read the latest documentation.
