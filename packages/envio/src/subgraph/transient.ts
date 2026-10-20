/**
 * Every host op that leaves the process — contract calls, balances, block
 * timestamps, IPFS, Arweave, ENS — runs through `untilAnswered`.
 *
 * envio exits on a handler error; it has no batch retry. So a transient failure
 * that escaped a host op would stop the whole indexer on one rate-limited call,
 * where graph-node backs off and asks again. Only a deterministic answer — a
 * value, a revert, a definite miss — may reach the mapping or end the run.
 */

import { warn } from "../Logging.res.mjs";

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

/** A response status, on our own fetch errors as on viem's. */
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

function transientStatus(status: number): boolean {
  return status === 408 || status === 425 || status === 429 || status >= 500;
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
    if (RATE_LIMIT_CODES.has(current.code)) return true;
    for (const text of [current.shortMessage, current.details, current.message]) {
      if (typeof text === "string" && TRANSIENT_TEXT.test(text)) return true;
    }
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
