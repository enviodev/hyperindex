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

const MAX_IN_FLIGHT = 16;

let inFlight = 0;
const queued: (() => void)[] = [];

async function bounded<T>(request: () => Promise<T>): Promise<T> {
  if (inFlight < MAX_IN_FLIGHT) inFlight++;
  // A finishing request hands its slot straight over.
  else await new Promise<void>((resolve) => queued.push(resolve));
  try {
    return await request();
  } finally {
    const next = queued.shift();
    if (next) next();
    else inFlight--;
  }
}

function boundedTransport(transport: Transport): Transport {
  return (options) => {
    const inner = transport(options);
    return {
      ...inner,
      request: ((args) => bounded(() => inner.request(args))) as typeof inner.request,
    };
  };
}

let clients = new Map<string, ReturnType<typeof createPublicClient>>();

export function rpcClient(rpcUrls: string[]) {
  const key = rpcUrls.join("|");
  let client = clients.get(key);
  if (!client) {
    client = createPublicClient({
      // Retrying is envio's job: a failed read becomes a handler error and
      // the batch is retried with the effect's dedup still in place.
      transport: boundedTransport(fallback(rpcUrls.map((url) => http(url, { retryCount: 0 })))),
    });
    clients.set(key, client);
  }
  return client;
}

/** Reset between test indexers, which each bring their own endpoints. */
export function resetRpcClients() {
  clients = new Map();
}
