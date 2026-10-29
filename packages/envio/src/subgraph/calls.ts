/**
 * `Contract.bind(x).foo()` -> an envio effect, encoded and decoded with
 * alloy, as graph-node does.
 *
 * graph-node evaluates a mapping's contract calls against the block the event
 * came from, so the block number is part of the effect's input — and therefore
 * of its cache key, which is what makes a cached call safe to reuse.
 */

import * as Sury from "rescript-schema";
import { subgraphAbiDecode, subgraphAbiEncodeCall } from "../Core.res.mjs";
import { createEffect } from "../Envio.res.mjs";
import { missingRpcMessage } from "./errors.ts";
import { rpcClient } from "./rpc.ts";
import { parseSignature } from "./abi-types.ts";
import { untilAnswered } from "./transient.ts";
import { info } from "./log.ts";

/**
 * A revert is data: the mapping's `try_` sees `{reverted: true}`. A transport
 * failure is not — `untilAnswered` asks again — so a flaky RPC never
 * fabricates reverted data.
 */
export function isRevert(error: unknown): boolean {
  const parts: string[] = [];
  let current: any = error;
  for (let depth = 0; current && depth < 10; depth++) {
    parts.push(current.name, current.shortMessage, current.details, current.message);
    current = current.cause;
  }
  const text = parts.filter(Boolean).join(" | ");

  if (/revert|invalid opcode|out of gas/i.test(text)) {
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

/**
 * BigInt and Bytes cross the effect boundary through Sury, which needs a
 * serialisable shape — so the call is described in plain JSON and the graph-ts
 * values are converted on both sides by the shim.
 */
/**
 * A batch commits only once every contract call its handlers make is in, and a
 * call-heavy backfill's first batch can wait minutes on thousands of them with
 * nothing else to show, which reads as a hang. While calls are
 * outstanding, how many were answered is logged now and then.
 */
const progress = { started: 0, answered: 0, reportedAnswered: 0, timer: undefined as NodeJS.Timeout | undefined };

function progressIntervalMs(): number {
  const value = Number(process.env.ENVIO_SUBGRAPH_PROGRESS_LOG_MS);
  return Number.isFinite(value) && value > 0 ? value : 30_000;
}

function reportProgress() {
  const waiting = progress.started - progress.answered;
  if (waiting <= 0) {
    clearInterval(progress.timer);
    progress.timer = undefined;
    return;
  }
  const interval = progressIntervalMs();
  const span = interval >= 1000 ? `${Math.round(interval / 1000)}s` : `${interval}ms`;
  info(
    `Envio Subgraph: ${progress.answered - progress.reportedAnswered} contract calls answered in the last ` +
      `${span}, ${waiting} waiting. The batch is written once its handlers' calls are all in.`,
  );
  progress.reportedAnswered = progress.answered;
}

function trackCall<T>(call: Promise<T>): Promise<T> {
  progress.started++;
  if (!progress.timer) {
    progress.timer = setInterval(reportProgress, progressIntervalMs());
    progress.timer.unref();
  }
  const settle = () => {
    progress.answered++;
  };
  call.then(settle, settle);
  return call;
}

/**
 * Functions whose answer a contract does not change once it has given one that
 * isn't empty: token metadata, a pair's tokens, a registry's factory. A mapping
 * asks them again at every block it handles (a token's `decimals()` on every
 * swap of every pair that holds it, a factory's `getPair(a, b)` on every sync)
 * and the effect cache keys a call by block, so each ask was an RPC request.
 * Once one has been answered at block B with a value, any block from B on gets
 * that value without a request. Only a non-empty answer counts: a zero address
 * or an empty string is "not there yet" (`getPair` before the pair exists,
 * `symbol()` before the token is deployed), and a revert is never shared.
 * A proxy that changes its `name()` later is the one case this gets wrong;
 * ENVIO_SUBGRAPH_EXACT_CALLS=1 asks every call at its own block instead.
 */
export const STABLE_FUNCTIONS = new Set([
  "name",
  "symbol",
  "decimals",
  "NAME",
  "SYMBOL",
  "DECIMALS",
  "token0",
  "token1",
  "factory",
  "getPair",
  "comptroller",
  "underlying",
]);

type Shared = { block: number; output: string };

/** The call without its block: what stays true from the block it was first answered at. */
function stableKey(input: CallInput): string | undefined {
  if (process.env.ENVIO_SUBGRAPH_EXACT_CALLS === "1") return undefined;
  if (!STABLE_FUNCTIONS.has(parseSignature(input.signature).name)) return undefined;
  // An address argument is the same one whatever its checksum casing.
  const args = input.args.map((arg) => (/^s:0x[0-9a-fA-F]*$/.test(String(arg)) ? String(arg).toLowerCase() : arg));
  return JSON.stringify([input.chainId, input.address.toLowerCase(), input.signature, args]);
}

const sharedAnswers = new Map<string, Shared>();
const sharedInFlight = new Map<string, { block: number; settled: Promise<void> }>();
const SHARED_ANSWERS_LIMIT = 200_000;

/** Reset between test indexers, which each bring their own chain. */
export function resetSharedCalls() {
  sharedAnswers.clear();
  sharedInFlight.clear();
}

function remember(key: string, block: number, output: string) {
  const answer = JSON.parse(output) as CallOutput;
  // A zero address or an empty string is "not there yet"; a revert says nothing.
  const empty = (answer.values ?? []).every((v) => typeof v === "string" && /^s:(0x0*)?$/i.test(v));
  if (answer.reverted || !answer.values || empty) return;
  const earlier = sharedAnswers.get(key);
  if (earlier && earlier.block <= block) return;
  if (sharedAnswers.size >= SHARED_ANSWERS_LIMIT) sharedAnswers.clear();
  sharedAnswers.set(key, { block, output });
}

/**
 * A stable function's answer from an earlier block, one still being asked for
 * (waited on, then reused if it turns out to be a value), or `ask`.
 */
export async function shareAcrossBlocks(input: CallInput, ask: () => Promise<string>): Promise<string> {
  const key = stableKey(input);
  if (key === undefined) return ask();
  const known = sharedAnswers.get(key);
  if (known && known.block <= input.blockNumber) return known.output;

  const running = sharedInFlight.get(key);
  if (running && running.block <= input.blockNumber) {
    await running.settled;
    const after = sharedAnswers.get(key);
    if (after && after.block <= input.blockNumber) return after.output;
  }

  const asked = ask();
  const entry = { block: input.blockNumber, settled: asked.then(() => undefined, () => undefined) };
  if (!sharedInFlight.has(key) || sharedInFlight.get(key)!.block > input.blockNumber) {
    sharedInFlight.set(key, entry);
  }
  try {
    const output = await asked;
    remember(key, input.blockNumber, output);
    return output;
  } finally {
    if (sharedInFlight.get(key) === entry) sharedInFlight.delete(key);
  }
}

/** An argument as the addon reads it: an integer as its decimal string. */
function jsonArg(value: unknown): unknown {
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) return value.map(jsonArg);
  return value;
}

const hexBytes = (hex: string) => Buffer.from(hex.replace(/^0x/, ""), "hex");

async function askNode(rpcUrls: string[], input: CallInput): Promise<string> {
  const { name, inputs, outputs } = parseSignature(input.signature);
  const data = subgraphAbiEncodeCall(name, `(${inputs})`, input.args.map(decodeArg).map(jsonArg));

  const result = await trackCall(
    untilAnswered(
      `${input.signature} on ${input.address} at block ${input.blockNumber}`,
      async () => {
        try {
          return await rpcClient(rpcUrls).call({ to: input.address, data, blockNumber: input.blockNumber });
        } catch (error) {
          if (isRevert(error)) return null;
          throw error;
        }
      },
      { deadline: false },
    ),
  );
  if (result === null) {
    return JSON.stringify({ reverted: true, values: null });
  }

  try {
    // graph-ts returns one `ethereum.Value` per ABI output. A single
    // tuple/struct is therefore `[tuple]`, not the flattened fields —
    // generated bindings call `result[0].toTuple()`.
    const values = subgraphAbiDecode(`(${outputs})`, hexBytes(result), true) as unknown[];
    return JSON.stringify({ reverted: false, values: values.map(encodeArg) });
  } catch {
    // Output the declared signature can't decode counts as a failed call,
    // which is what lets a mapping retry through a different ABI — the
    // bytes32-vs-string ERC20 name is the case every token subgraph hits. A
    // function answering no bytes at all is the same: the account has no code.
    return JSON.stringify({ reverted: true, values: null });
  }
}

export function makeCallEffect(rpcUrls: string[], recall: (encoded: string) => string | undefined = () => undefined) {
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
      // The register pass asked the same question at fetch time; its answer
      // is the same one, and asking twice doubled a factory's calls.
      const recalled = recall(encoded);
      if (recalled !== undefined) return recalled;
      const input = JSON.parse(encoded) as CallInput;
      if (rpcUrls.length === 0) {
        throw new Error(missingRpcMessage(input.signature));
      }
      return shareAcrossBlocks(input, () => askNode(rpcUrls, input));
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
