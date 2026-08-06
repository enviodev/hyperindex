/**
 * `Contract.bind(x).foo()` -> an envio effect over viem.
 *
 * graph-node evaluates a mapping's contract calls against the block the event
 * came from, so the block number is part of the effect's input — and therefore
 * of its cache key, which is what makes a cached call safe to reuse.
 */

import {
  createPublicClient,
  decodeFunctionResult,
  encodeFunctionData,
  fallback,
  http,
  parseAbiParameters,
  type Abi,
} from "viem";
import * as Sury from "rescript-schema";
import { createEffect } from "../Envio.res.mjs";
import { missingRpcMessage } from "./errors.ts";

export type ParsedSignature = {
  name: string;
  inputs: string;
  outputs: string;
};

/**
 * graph codegen emits `"balanceOf(address):(uint256)"`. Types only, no names —
 * which is all `parseAbiParameters` needs.
 */
export function parseSignature(signature: string): ParsedSignature {
  const open = signature.indexOf("(");
  if (open === -1) {
    throw new Error(`Unreadable contract call signature "${signature}"`);
  }
  const name = signature.slice(0, open);

  let depth = 0;
  let close = -1;
  for (let index = open; index < signature.length; index++) {
    const char = signature[index];
    if (char === "(") depth++;
    if (char === ")") {
      depth--;
      if (depth === 0) {
        close = index;
        break;
      }
    }
  }
  if (close === -1) {
    throw new Error(`Unreadable contract call signature "${signature}"`);
  }

  const inputs = signature.slice(open + 1, close);
  const rest = signature.slice(close + 1).replace(/^:/, "");
  const outputs = rest.startsWith("(") ? rest.slice(1, -1) : rest;

  return { name, inputs, outputs };
}

export function abiItemFor(signature: string): Abi {
  const { name, inputs, outputs } = parseSignature(signature);
  return [
    {
      type: "function",
      name,
      stateMutability: "view",
      inputs: inputs.trim() === "" ? [] : [...parseAbiParameters(inputs)],
      outputs: outputs.trim() === "" ? [] : [...parseAbiParameters(outputs)],
    },
  ] as Abi;
}

/**
 * A revert is data: the mapping's `try_` sees `{reverted: true}`. A transport
 * failure is not — it throws as the handler error so envio retries, and a flaky
 * RPC never fabricates reverted data.
 */
export function isRevert(error: unknown): boolean {
  const parts: string[] = [];
  let current: any = error;
  for (let depth = 0; current && depth < 10; depth++) {
    parts.push(current.name, current.shortMessage, current.details, current.message);
    current = current.cause;
  }
  const text = parts.filter(Boolean).join(" | ");

  if (/revert|ContractFunctionZeroDataError|invalid opcode|out of gas/i.test(text)) {
    return true;
  }
  return false;
}

export type CallInput = {
  chainId: number;
  address: string;
  signature: string;
  args: unknown[];
  blockNumber: number;
};

export type CallOutput = {
  reverted: boolean;
  values: unknown[] | null;
};

let clients: Map<string, ReturnType<typeof createPublicClient>> = new Map();

function clientFor(rpcUrls: string[]) {
  const key = rpcUrls.join("|");
  let client = clients.get(key);
  if (!client) {
    client = createPublicClient({
      // Retrying is envio's job: a failed call becomes a handler error and
      // the batch is retried with the effect's dedup still in place.
      transport: fallback(rpcUrls.map((url) => http(url, { retryCount: 0 }))),
    });
    clients.set(key, client);
  }
  return client;
}

/** Reset between test indexers, which each bring their own endpoints. */
export function resetClients() {
  clients = new Map();
}

/**
 * BigInt and Bytes cross the effect boundary through Sury, which needs a
 * serialisable shape — so the call is described in plain JSON and the graph-ts
 * values are converted on both sides by the shim.
 */
export function makeCallEffect(rpcUrls: string[]) {
  return createEffect(
    {
      name: "envio_subgraph_eth_call",
      // Both sides travel as JSON text: the cache key is then the exact call
      // description, and the cached row is readable.
      input: Sury.string,
      output: Sury.string,
      rateLimit: false,
      cache: true,
      crossChain: false,
    },
    async ({ input: encoded }: { input: string }) => {
      const input = JSON.parse(encoded) as CallInput;
      if (rpcUrls.length === 0) {
        throw new Error(missingRpcMessage(input.signature));
      }
      const abi = abiItemFor(input.signature);
      const { name } = parseSignature(input.signature);
      const data = encodeFunctionData({
        abi,
        functionName: name,
        args: input.args.map(decodeArg),
      });

      try {
        const result = await clientFor(rpcUrls).call({
          to: input.address as `0x${string}`,
          data,
          blockNumber: BigInt(input.blockNumber),
        });
        const decoded = decodeFunctionResult({
          abi,
          functionName: name,
          data: (result.data ?? "0x") as `0x${string}`,
        });
        const values = Array.isArray(decoded) ? decoded : [decoded];
        return JSON.stringify({ reverted: false, values: values.map(encodeArg) });
      } catch (error) {
        if (isRevert(error)) {
          return JSON.stringify({ reverted: true, values: null });
        }
        throw error;
      }
    },
  );
}

/** Effect inputs/outputs travel as strings, tagged so the type survives. */
export function encodeArg(value: unknown): string {
  if (typeof value === "bigint") return `i:${value.toString()}`;
  if (typeof value === "boolean") return `b:${value ? "1" : "0"}`;
  if (Array.isArray(value)) return `a:${JSON.stringify(value.map(encodeArg))}`;
  return `s:${String(value)}`;
}

export function decodeArg(value: string): unknown {
  const tag = value.slice(0, 2);
  const body = value.slice(2);
  switch (tag) {
    case "i:":
      return BigInt(body);
    case "b:":
      return body === "1";
    case "a:":
      return (JSON.parse(body) as string[]).map(decodeArg);
    default:
      return body;
  }
}
