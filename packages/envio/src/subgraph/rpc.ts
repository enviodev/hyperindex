/**
 * The one client every RPC read of the subgraph runtime goes through: contract
 * calls, `getBalance`/`hasCode` and block timestamps.
 *
 * Preload runs a batch's handlers at once, and with them every read they make.
 * Unbounded, that is one open connection per read — thousands on a factory's
 * backfill, until the endpoint stops answering and the batch never completes.
 * So requests beyond a fixed number wait for one in flight to finish; each is
 * short, and a queue drains far faster than a refused connection retries.
 */

import { createPublicClient, createTransport, fallback, RpcRequestError, type Transport } from "viem";
import { getHttpRpcClient } from "viem/utils";
import { requestTimeoutMs, withDeadline } from "./transient.ts";

/**
 * Requests in flight at once, per set of endpoints. A handler's calls run one
 * after another (a decimals call, then a name, then a price), so a batch's
 * throughput is this many divided by the endpoint's latency: at 16 and a
 * second a call — a shared or distant endpoint — a batch of five thousand
 * events took minutes to commit. `ENVIO_SUBGRAPH_RPC_CONCURRENCY` overrides it.
 */
const DEFAULT_MAX_IN_FLIGHT = 48;

function maxInFlightFromEnv(): number {
  const value = Number(process.env.ENVIO_SUBGRAPH_RPC_CONCURRENCY);
  return Number.isInteger(value) && value > 0 ? value : DEFAULT_MAX_IN_FLIGHT;
}

/**
 * Most requests one HTTP request carries as a JSON-RPC batch. Requests that
 * queue while every connection is busy leave together, so a backfill's calls
 * take a round trip per batch rather than per call. `ENVIO_SUBGRAPH_RPC_BATCH`
 * overrides it; 1 sends every request on its own.
 */
const DEFAULT_MAX_BATCH = 32;

function maxBatchFromEnv(): number {
  const value = Number(process.env.ENVIO_SUBGRAPH_RPC_BATCH);
  return Number.isInteger(value) && value > 0 ? value : DEFAULT_MAX_BATCH;
}

/**
 * Runs at most `the limit at once, queueing the rest. A slot is
 * held at most the request deadline: one that never settles would otherwise
 * keep it for good, and a handful of those stall every call behind them with
 * no connection doing anything.
 */
export function gate(maxInFlight = maxInFlightFromEnv()) {
  let inFlight = 0;
  const queued: (() => void)[] = [];
  return async <T>(request: () => Promise<T>): Promise<T> => {
    if (inFlight < maxInFlight) inFlight++;
    // A finishing request hands its slot straight over.
    else await new Promise<void>((resolve) => queued.push(resolve));
    try {
      return await withDeadline("The RPC request", request);
    } finally {
      const next = queued.shift();
      if (next) next();
      else inFlight--;
    }
  };
}

type Body = { method: string; params?: unknown };
type Answer = { result?: unknown; error?: { code: number; message: string; data?: unknown } };
type Waiting = { body: Body; resolve: (answer: Answer) => void; reject: (error: unknown) => void; missing: number };

/**
 * An endpoint's own words for "this batch is too big" (dRPC's free plan:
 * "Batch of more than 3 requests are not allowed"), said per item.
 */
function isBatchLimit(error: Answer["error"]): boolean {
  const message = String(error?.message ?? "");
  return /batch/i.test(message) && /more than|too (many|large|big)|exceed|limit|not allowed|maximum|size/i.test(message);
}

/** The size such a message allows, when it says. */
function allowedBatch(error: Answer["error"]): number | undefined {
  const match = /more than (\d+)|(?:maximum|max|limit)[^\d]{0,20}(\d+)/i.exec(String(error?.message ?? ""));
  const value = Number(match?.[1] ?? match?.[2]);
  return Number.isInteger(value) && value > 0 ? value : undefined;
}

/** Times a batch item may come back without its answer before it fails on its own. */
const MAX_MISSING = 3;

/**
 * One endpoint, `maxInFlight` HTTP requests at a time, each carrying up to the
 * batch size the endpoint takes. Every request keeps exactly the answer it
 * would get sent alone: items are matched to their answers by id, a JSON-RPC
 * error stays that item's error (a revert reaches only the call that
 * reverted), and HTTP failures fail every item they carried, to be asked
 * again by `untilAnswered`. An endpoint that refuses a batch — HTTP 4xx, an
 * error in place of the array, or a "batch too large" answer per item — gets
 * smaller ones from then on, down to plain single requests.
 */
function batchingTransport(url: string, maxInFlight: number, maxBatch: number): Transport {
  const client = getHttpRpcClient(url, { timeout: requestTimeoutMs() });
  let batchSize = maxBatch;
  let inFlight = 0;
  let pumpScheduled = false;
  let nextId = 1;
  const queue: Waiting[] = [];

  const shrink = (to?: number) => {
    batchSize = Math.max(1, Math.min(to ?? Math.floor(batchSize / 2), batchSize - 1));
  };

  const send = async (items: Waiting[]) => {
    if (items.length === 1) {
      const [item] = items;
      try {
        item.resolve((await client.request({ body: item.body as any })) as Answer);
      } catch (error) {
        item.reject(error);
      }
      return;
    }
    const ids = items.map(() => nextId++);
    let data: unknown;
    try {
      data = await client.request({ body: items.map((item, i) => ({ ...item.body, id: ids[i] })) as any });
    } catch (error) {
      const status = (error as { status?: unknown }).status;
      if (typeof status === "number" && status >= 400 && status < 500 && status !== 408 && status !== 429) {
        shrink();
        queue.unshift(...items);
        return;
      }
      for (const item of items) item.reject(error);
      return;
    }
    if (!Array.isArray(data)) {
      // An error in place of the array: the endpoint takes no batch this big.
      shrink();
      queue.unshift(...items);
      return;
    }
    const byId = new Map<unknown, Answer>();
    for (const answer of data) if (answer && typeof answer === "object") byId.set((answer as any).id, answer as Answer);
    const again: Waiting[] = [];
    items.forEach((item, i) => {
      const answer = byId.get(ids[i]);
      if (answer === undefined) {
        if (++item.missing >= MAX_MISSING) {
          item.reject(new Error(`${url} answered a batch without the answer to ${item.body.method}; asking again.`));
        } else again.push(item);
        return;
      }
      if (answer.error && isBatchLimit(answer.error)) {
        shrink(allowedBatch(answer.error));
        again.push(item);
        return;
      }
      item.resolve(answer);
    });
    if (again.length > 0) queue.unshift(...again);
  };

  const pump = () => {
    pumpScheduled = false;
    while (inFlight < maxInFlight && queue.length > 0) {
      const items = queue.splice(0, batchSize);
      inFlight++;
      void send(items).finally(() => {
        inFlight--;
        pump();
      });
    }
  };

  return () =>
    createTransport({
      key: "http",
      name: "HTTP JSON-RPC",
      type: "http",
      retryCount: 0,
      timeout: requestTimeoutMs(),
      request: (async ({ method, params }: Body) => {
        const body = { method, params };
        const answer = await new Promise<Answer>((resolve, reject) => {
          queue.push({ body, resolve, reject, missing: 0 });
          // Requests made in the same turn — preload's calls, a batch's
          // timestamps — leave together.
          if (!pumpScheduled) {
            pumpScheduled = true;
            setImmediate(pump);
          }
        });
        if (answer.error) throw new RpcRequestError({ body, error: answer.error, url });
        return answer.result;
      }) as any,
    });
}

const clients = new Map<string, ReturnType<typeof createPublicClient>>();

export function rpcClient(rpcUrls: string[]) {
  const key = rpcUrls.join("|");
  let client = clients.get(key);
  if (!client) {
    const maxInFlight = maxInFlightFromEnv();
    const maxBatch = maxBatchFromEnv();
    client = createPublicClient({
      // Retrying is `untilAnswered`'s job, with a backoff that outlasts a rate
      // limit; viem's own would give up within a second.
      transport: fallback(
        rpcUrls.map((url) => batchingTransport(url, maxInFlight, maxBatch)),
        { retryCount: 0 },
      ),
    });
    clients.set(key, client);
  }
  return client;
}

/** Reset between test indexers, which each bring their own endpoints. */
export function resetRpcClients() {
  clients.clear();
}
