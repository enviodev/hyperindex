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

import { createPublicClient, fallback, http, type Transport } from "viem";
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

/** Bounded per set of endpoints, so one chain's slow RPC can't stall another's. */
function boundedTransport(transport: Transport): Transport {
  const bounded = gate();
  return (options) => {
    const inner = transport(options);
    return {
      ...inner,
      request: ((args) => bounded(() => inner.request(args))) as typeof inner.request,
    };
  };
}

const clients = new Map<string, ReturnType<typeof createPublicClient>>();

export function rpcClient(rpcUrls: string[]) {
  const key = rpcUrls.join("|");
  let client = clients.get(key);
  if (!client) {
    client = createPublicClient({
      // Retrying is `untilAnswered`'s job, with a backoff that outlasts a rate
      // limit; viem's own would give up within a second.
      transport: boundedTransport(
        fallback(
          rpcUrls.map((url) => http(url, { retryCount: 0, timeout: requestTimeoutMs() })),
          { retryCount: 0 },
        ),
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
