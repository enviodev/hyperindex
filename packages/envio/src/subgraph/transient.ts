/**
 * Every host op that leaves the process — contract calls, balances, block
 * timestamps, IPFS, Arweave, ENS — runs through `untilAnswered`.
 *
 * envio exits on a handler error; it has no batch retry. So a transient failure
 * that escaped a host op would stop the whole indexer on one rate-limited call,
 * where graph-node backs off and asks again. Only a deterministic answer — a
 * value, a revert, a definite miss — may reach the mapping or end the run.
 */

import { warn } from "./log.ts";

const MAX_BACKOFF_MS = 30_000;

function positive(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

/** Each attempt's deadline: a request that never answers is given up on. */
export function requestTimeoutMs(): number {
  return positive("ENVIO_SUBGRAPH_REQUEST_TIMEOUT_MS", 30_000);
}

function firstBackoffMs(): number {
  return positive("ENVIO_SUBGRAPH_RETRY_BACKOFF_MS", 500);
}

/** A response status the endpoint answered with. */
export class HttpStatusError extends Error {
  constructor(
    readonly url: string,
    readonly status: number,
    statusText: string,
  ) {
    super(`${url} answered ${status} ${statusText}`.trim());
  }
}

class AttemptTimeout extends Error {
  constructor(what: string, ms: number) {
    super(`${what} didn't answer within ${ms}ms`);
  }
}

const TRANSIENT_TEXT =
  /rate.?limit|too many requests|capacity|limit exceeded|exceeds? (the |its |defined )?limit|timed? ?out|timeout|header not found|ECONNRESET|ECONNREFUSED|EPIPE|ETIMEDOUT|EAI_AGAIN|ENOTFOUND|socket hang up|fetch failed|network|temporar|unavailable|overloaded|busy|try again/i;

/**
 * JSON-RPC codes public endpoints send for "slow down": -32005 "limit
 * exceeded" (Infura, Tenderly), -32097 (blastapi), -32090 (Alchemy).
 */
const RATE_LIMIT_CODES = new Set([-32005, -32097, -32090]);

/**
 * The rate limits, and the node's own failure, -32603 "Internal error", which
 * the same request answers on the next try. graph-node asks again after every
 * eth_call error that isn't a revert (`interpret_eth_call_error`).
 */
const TRANSIENT_CODES = new Set([...RATE_LIMIT_CODES, -32603]);

function transientStatus(status: number): boolean {
  return status === 408 || status === 425 || status === 429 || status >= 500;
}

const RATE_LIMIT_TEXT = /rate.?limit|too many requests|request limit|limit exceeded/i;

/**
 * The endpoint saying "slow down" — HTTP 429, or a JSON-RPC rate-limit error —
 * on an error or on a JSON-RPC error object, anywhere down its cause chain.
 */
export function isRateLimit(error: unknown): boolean {
  let current: any = error;
  for (let depth = 0; current && depth < 10; depth++) {
    if (current.status === 429 || current.code === 429 || RATE_LIMIT_CODES.has(current.code)) return true;
    if (typeof current.message === "string" && RATE_LIMIT_TEXT.test(current.message)) return true;
    current = current.cause;
  }
  return false;
}

/**
 * Whether asking again could get a different answer. A status decides it when
 * there is one; otherwise the error's own words do, down its cause chain.
 */
export function isTransient(error: unknown): boolean {
  let current: any = error;
  for (let depth = 0; current && depth < 10; depth++) {
    if (current instanceof AttemptTimeout) return true;
    if (current.name === "AbortError" || current.name === "TimeoutError") return true;
    if (typeof current.status === "number") return transientStatus(current.status);
    if (TRANSIENT_CODES.has(current.code)) return true;
    if (typeof current.message === "string" && TRANSIENT_TEXT.test(current.message)) return true;
    current = current.cause;
  }
  return false;
}

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * One try, given `requestTimeoutMs`. The deadline holds even if the attempt
 * ignores its signal, so a hung request can't stall the handler waiting on it.
 */
export async function withDeadline<T>(
  what: string,
  attempt: (signal: AbortSignal) => Promise<T>,
): Promise<T> {
  const timeout = requestTimeoutMs();
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      const error = new AttemptTimeout(what, timeout);
      controller.abort(error);
      reject(error);
    }, timeout);
  });
  try {
    return await Promise.race([attempt(controller.signal), deadline]);
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Tries `attempt` until it answers, backing off exponentially between transient
 * failures. With `maxTries`, the last transient failure is thrown once that
 * many attempts have failed; with `budgetMs`, once the next wait would end
 * past that long after the first attempt.
 */
export async function untilAnswered<T>(
  what: string,
  attempt: (signal: AbortSignal) => Promise<T>,
  {
    maxTries = Infinity,
    // An attempt that goes through a gate (`rpc.ts`) gets its deadline there,
    // once it holds a slot: timed from here, a request still queued behind
    // the gate would time out unsent, be asked again, and be sent twice.
    deadline = true,
    budgetMs = Infinity,
  }: { maxTries?: number; deadline?: boolean; budgetMs?: number } = {},
): Promise<T> {
  const started = Date.now();
  for (let tries = 0; ; tries++) {
    try {
      return await (deadline ? withDeadline(what, attempt) : attempt(new AbortController().signal));
    } catch (error) {
      if (!isTransient(error) || tries + 1 >= maxTries) throw error;
      const wait = Math.min(firstBackoffMs() * 2 ** tries, MAX_BACKOFF_MS);
      if (Date.now() - started + wait > budgetMs) throw error;
      const reason = error instanceof Error ? error.message.split("\n")[0] : String(error);
      warn(`Envio Subgraph: ${what} failed (${reason}); asking again in ${wait}ms.`);
      await sleep(wait);
    }
  }
}

/**
 * A revert is data: the mapping's `try_` sees `{reverted: true}`, and every
 * node gives the same one. Geth says it in the message; Parity, OpenEthereum
 * and older Nethermind answer -32015 "VM execution error." and say it in the
 * error's data ("Reverted 0x…"), as graph-node reads them.
 */
export function isRevert(error: unknown): boolean {
  let current: any = error;
  for (let depth = 0; current && depth < 10; depth++) {
    for (const text of [current.message, current.data]) {
      if (typeof text === "string" && REVERT_TEXT.test(text)) return true;
    }
    current = current.cause;
  }
  return false;
}

const REVERT_TEXT = /revert|invalid opcode|bad instruction|bad jump|out of gas/i;
