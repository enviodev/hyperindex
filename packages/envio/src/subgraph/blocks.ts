/**
 * A block handler's `block.timestamp`.
 *
 * envio hands a block handler only the block number, so the timestamp has to be
 * fetched. Every handler invocation in a batch asks within the same microtask,
 * so the requests are collected and answered by a single HyperSync range query
 * rather than one round trip per block. An RPC endpoint, if one is configured,
 * is the fallback for whatever HyperSync couldn't answer.
 */

import { createPublicClient, fallback, http } from "viem";

const API_TOKEN_ENV_VAR = "ENVIO_API_TOKEN";

const hypersyncUrl = (chainId: number) => `https://${chainId}.hypersync.xyz/query`;

type Waiter = {
  resolve: (timestamp: bigint) => void;
  reject: (error: unknown) => void;
};

/** Blocks asked for since the last flush, by chain then block number. */
let pending = new Map<number, Map<number, Waiter[]>>();
let flushScheduled = false;

let rpcUrls: string[] = [];
let client: ReturnType<typeof createPublicClient> | null = null;

export function configureBlockTimestamps(urls: string[]) {
  rpcUrls = urls;
  client = null;
  pending = new Map();
  flushScheduled = false;
}

export function requestBlockTimestamp(chainId: number, blockNumber: number): Promise<bigint> {
  return new Promise((resolve, reject) => {
    let blocks = pending.get(chainId);
    if (!blocks) {
      blocks = new Map();
      pending.set(chainId, blocks);
    }
    const waiters = blocks.get(blockNumber);
    if (waiters) {
      waiters.push({ resolve, reject });
    } else {
      blocks.set(blockNumber, [{ resolve, reject }]);
    }

    if (!flushScheduled) {
      flushScheduled = true;
      queueMicrotask(() => {
        flushScheduled = false;
        const collected = pending;
        pending = new Map();
        for (const [chain, blocksForChain] of collected) {
          void answer(chain, blocksForChain);
        }
      });
    }
  });
}

async function answer(chainId: number, blocks: Map<number, Waiter[]>) {
  const wanted = [...blocks.keys()];
  let timestamps = new Map<number, bigint>();

  try {
    timestamps = await fromHyperSync(chainId, Math.min(...wanted), Math.max(...wanted));
  } catch (error) {
    if (rpcUrls.length === 0) {
      const message = error instanceof Error ? error.message : String(error);
      for (const waiters of blocks.values()) {
        for (const waiter of waiters) {
          waiter.reject(
            new Error(
              `Envio Subgraph couldn't read a block timestamp from HyperSync: ${message}\n` +
                `Set ${API_TOKEN_ENV_VAR} in .env or the environment — create one at\n` +
                `https://envio.dev/app/api-tokens — or set ENVIO_SUBGRAPH_RPC to fall back to RPC.`,
            ),
          );
        }
      }
      return;
    }
  }

  for (const [blockNumber, waiters] of blocks) {
    const known = timestamps.get(blockNumber);
    if (known !== undefined) {
      for (const waiter of waiters) waiter.resolve(known);
      continue;
    }
    try {
      const timestamp = await fromRpc(blockNumber);
      for (const waiter of waiters) waiter.resolve(timestamp);
    } catch (error) {
      for (const waiter of waiters) waiter.reject(error);
    }
  }
}

type HyperSyncResponse = {
  data: { blocks?: { number: number; timestamp: string }[] }[];
  next_block: number;
};

async function fromHyperSync(
  chainId: number,
  fromBlock: number,
  toBlock: number,
): Promise<Map<number, bigint>> {
  const token = process.env[API_TOKEN_ENV_VAR];
  const timestamps = new Map<number, bigint>();

  let cursor = fromBlock;
  // HyperSync answers as much of the range as one response holds and points at
  // where to resume, so a wide range takes more than one round trip.
  while (cursor <= toBlock) {
    const response = await fetch(hypersyncUrl(chainId), {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify({
        from_block: cursor,
        to_block: toBlock + 1,
        include_all_blocks: true,
        field_selection: { block: ["number", "timestamp"] },
      }),
    });

    if (!response.ok) {
      throw new Error(`HyperSync returned ${response.status} ${await response.text()}`);
    }

    const body = (await response.json()) as HyperSyncResponse;
    for (const page of body.data ?? []) {
      for (const block of page.blocks ?? []) {
        timestamps.set(block.number, BigInt(block.timestamp));
      }
    }

    if (!body.next_block || body.next_block <= cursor) {
      break;
    }
    cursor = body.next_block;
  }

  return timestamps;
}

async function fromRpc(blockNumber: number): Promise<bigint> {
  if (rpcUrls.length === 0) {
    throw new Error(
      `Envio Subgraph couldn't read the timestamp of block ${blockNumber}: HyperSync didn't\n` +
        `return it, and no RPC fallback is configured. Set ENVIO_SUBGRAPH_RPC in .env or the\n` +
        `environment.`,
    );
  }
  client ??= createPublicClient({
    transport: fallback(rpcUrls.map((url) => http(url, { retryCount: 0 }))),
  });
  const block = await client.getBlock({ blockNumber: BigInt(blockNumber) });
  return block.timestamp;
}
