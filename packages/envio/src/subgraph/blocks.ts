/**
 * A block handler's `block.timestamp` and header fields, and the batching they
 * share.
 *
 * envio hands a block handler only the block number, so the timestamp has to be
 * fetched. Every handler invocation in a batch asks within the same microtask,
 * so the requests are collected and answered by a HyperSync range query per
 * cluster of nearby blocks rather than one round trip per block. An RPC endpoint, if one is configured,
 * is the fallback for whatever HyperSync couldn't answer.
 *
 * `block.hash` and the other header fields ride the same path, as a second
 * batcher so a handler that only reads the timestamp keeps its narrow
 * queries. Fetched after the batch, a header is outside the reorg guard that
 * validates an event's block, so it is only ever served from below the
 * chain's head by its reorg depth: the translator holds the chain back by
 * that much, and HyperSync's answers are checked against it here too.
 */

import { rpcClient } from "./rpc.ts";
import { HttpStatusError, untilAnswered, withDeadline } from "./transient.ts";

const API_TOKEN_ENV_VAR = "ENVIO_API_TOKEN";

const hypersyncUrl = (chainId: number) => `https://${chainId}.hypersync.xyz/query`;

type Waiter<T> = {
  resolve: (value: T) => void;
  reject: (error: unknown) => void;
};

let rpcUrls: string[] = [];
/** Per chain, how far below the head a header must sit before it is served. */
let headerLag: Record<number, number> = {};
/** Chains HyperSync doesn't serve, which RPC answers alone. */
let rpcOnly = new Set<number>();

export function configureBlockTimestamps(
  urls: string[],
  lag: Record<number, number> = {},
  rpcOnlyChains: number[] = [],
) {
  rpcUrls = urls;
  headerLag = lag;
  rpcOnly = new Set(rpcOnlyChains);
  timestamps.reset();
  headers.reset();
}

/** A block's header as envio names its fields, every value a hex or decimal string. */
export type BlockHeader = Record<string, string | null>;

type Fetched<T> = { blocks: Map<number, T>; archiveHeight?: number };

type Batcher<T> = {
  request: (chainId: number, blockNumber: number) => Promise<T>;
  reset: () => void;
};

/**
 * Collects the blocks asked for within one microtask and answers them with
 * HyperSync range queries, falling back to RPC for what it didn't return.
 */
function makeBatcher<T>(
  what: string,
  fromHyperSync: (chainId: number, from: number, to: number) => Promise<Fetched<T>>,
  fromRpc: (chainId: number, blockNumber: number) => Promise<T>,
): Batcher<T> {
  /** Blocks asked for since the last flush, by chain then block number. */
  let pending = new Map<number, Map<number, Waiter<T>[]>>();
  let flushScheduled = false;

  async function answer(chainId: number, blocks: Map<number, Waiter<T>[]>) {
    let answers = new Map<number, T>();

    // HyperSync isn't asked for a chain it doesn't serve: where a firewall
    // drops the connection rather than refusing it, asking held the batch for
    // the request deadline.
    const askHyperSync = !(rpcOnly.has(chainId) && rpcUrls.length > 0);
    try {
      if (askHyperSync) {
        const fetched = await bounded(
          clusters([...blocks.keys()]).map(([from, to]) => () => fromHyperSync(chainId, from, to)),
          MAX_QUERIES_IN_FLIGHT,
        );
        answers = new Map(fetched.flatMap((cluster) => [...cluster.blocks]));
      }
    } catch (error) {
      if (rpcUrls.length === 0) {
        const message = error instanceof Error ? error.message : String(error);
        for (const waiters of blocks.values()) {
          for (const waiter of waiters) {
            waiter.reject(
              new Error(
                `Envio Subgraph couldn't read a block ${what} from HyperSync: ${message}\n` +
                  `Set ${API_TOKEN_ENV_VAR} in .env or the environment — create one at\n` +
                  `https://envio.dev/app/api-tokens — or set ENVIO_SUBGRAPH_RPC to fall back to RPC.`,
              ),
            );
          }
        }
        return;
      }
    }

    // What HyperSync didn't answer is asked of RPC all at once: the client
    // bounds the requests in flight, and one at a time a chain HyperSync
    // doesn't serve paid the endpoint's latency once per block.
    await Promise.all(
      [...blocks].map(async ([blockNumber, waiters]) => {
        const known = answers.get(blockNumber);
        if (known !== undefined) {
          for (const waiter of waiters) waiter.resolve(known);
          return;
        }
        try {
          const value = await fromRpc(chainId, blockNumber);
          for (const waiter of waiters) waiter.resolve(value);
        } catch (error) {
          for (const waiter of waiters) waiter.reject(error);
        }
      }),
    );
  }

  return {
    request(chainId, blockNumber) {
      return new Promise<T>((resolve, reject) => {
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
    },
    reset() {
      pending = new Map();
      flushScheduled = false;
    },
  };
}

/**
 * Gaps narrower than one response's worth of headers are fetched through
 * rather than split: a polling handler every few blocks is one query, one
 * every 100,000 is one tiny query per block.
 */
const CLUSTER_GAP = 10_000;
/**
 * A range is paged one response at a time, so merging without bound turned a
 * polling handler every 1,600 blocks into one scan over the whole batch —
 * Notional's 3.2M blocks, 38 s per timestamp. Capped, the pieces run side by
 * side.
 */
const MAX_CLUSTER_SPAN = 20_000;
const MAX_QUERIES_IN_FLIGHT = 8;

/** The requested blocks as `[from, to]` ranges, in order. */
function clusters(blockNumbers: number[]): [number, number][] {
  const sorted = [...blockNumbers].sort((a, b) => a - b);
  const ranges: [number, number][] = [];
  for (const blockNumber of sorted) {
    const last = ranges[ranges.length - 1];
    if (last && blockNumber - last[1] <= CLUSTER_GAP && blockNumber - last[0] < MAX_CLUSTER_SPAN) {
      last[1] = blockNumber;
    } else ranges.push([blockNumber, blockNumber]);
  }
  return ranges;
}

/** Runs `tasks` with at most `limit` of them at once, keeping their order. */
async function bounded<T>(tasks: (() => Promise<T>)[], limit: number): Promise<T[]> {
  const results: T[] = new Array(tasks.length);
  let next = 0;
  const worker = async () => {
    while (next < tasks.length) {
      const index = next++;
      results[index] = await tasks[index]();
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, tasks.length) }, worker));
  return results;
}


type HyperSyncResponse = {
  data: { blocks?: Record<string, string>[] }[];
  next_block: number;
  archive_height?: number | null;
};

/**
 * One HyperSync range of blocks, `fields` selected, each block turned into a
 * `T` by `parse`. A wide range takes more than one round trip: HyperSync answers
 * as much of it as one response holds and points at where to resume.
 */
async function hyperSyncBlocks<T>(
  chainId: number,
  fromBlock: number,
  toBlock: number,
  fields: string[],
  parse: (block: Record<string, string>) => T,
  what: string,
): Promise<Fetched<T>> {
  const token = process.env[API_TOKEN_ENV_VAR];
  const blocks = new Map<number, T>();
  let archiveHeight: number | undefined;

  let cursor = fromBlock;
  while (cursor <= toBlock) {
    const url = hypersyncUrl(chainId);
    const from = cursor;
    // With an RPC to fall back to, one try: a failing HyperSync hands the
    // blocks to RPC rather than holding them until it recovers.
    const ask = rpcUrls.length > 0 ? withDeadline : untilAnswered;
    const body = await ask(
      `HyperSync's ${what} of blocks ${from}-${toBlock}`,
      async (signal): Promise<HyperSyncResponse> => {
        const response = await fetch(url, {
          method: "POST",
          signal,
          headers: {
            "content-type": "application/json",
            ...(token ? { authorization: `Bearer ${token}` } : {}),
          },
          body: JSON.stringify({
            from_block: from,
            to_block: toBlock + 1,
            include_all_blocks: true,
            field_selection: { block: fields },
          }),
        });
        if (!response.ok) {
          throw new HttpStatusError(url, response.status, await response.text());
        }
        return (await response.json()) as HyperSyncResponse;
      },
    );
    for (const page of body.data ?? []) {
      for (const block of page.blocks ?? []) {
        blocks.set(Number(block.number), parse(block));
      }
    }
    if (typeof body.archive_height === "number") archiveHeight = body.archive_height;

    if (!body.next_block || body.next_block <= cursor) {
      break;
    }
    cursor = body.next_block;
  }

  return { blocks, archiveHeight };
}

const timestamps = makeBatcher<bigint>(
  "timestamp",
  async (chainId, from, to) =>
    hyperSyncBlocks(
      chainId,
      from,
      to,
      ["number", "timestamp"],
      (block) => BigInt(block.timestamp),
      "timestamps",
    ),
  async (_chainId, blockNumber) => {
    if (rpcUrls.length === 0) {
      throw new Error(
        `Envio Subgraph couldn't read the timestamp of block ${blockNumber}: HyperSync didn't\n` +
          `return it, and no RPC fallback is configured. Set ENVIO_SUBGRAPH_RPC in .env or the\n` +
          `environment.`,
      );
    }
    const client = rpcClient(rpcUrls);
    const block = await untilAnswered(
      `block ${blockNumber} from RPC`,
      () => client.getBlock({ blockNumber }),
      { deadline: false },
    );
    return BigInt(block.timestamp);
  },
);

export function requestBlockTimestamp(chainId: number, blockNumber: number): Promise<bigint> {
  return timestamps.request(chainId, blockNumber);
}

/** HyperSync's block columns, under the names envio decodes a block's fields as. */
const HEADER_COLUMNS: Record<string, string> = {
  number: "number",
  hash: "hash",
  parent_hash: "parentHash",
  sha3_uncles: "sha3Uncles",
  miner: "miner",
  state_root: "stateRoot",
  transactions_root: "transactionsRoot",
  receipts_root: "receiptsRoot",
  gas_used: "gasUsed",
  gas_limit: "gasLimit",
  difficulty: "difficulty",
  total_difficulty: "totalDifficulty",
  size: "size",
  base_fee_per_gas: "baseFeePerGas",
  timestamp: "timestamp",
};

function headerFromHyperSync(block: Record<string, string>): BlockHeader {
  const header: BlockHeader = {};
  for (const [column, name] of Object.entries(HEADER_COLUMNS)) {
    header[name] = block[column] ?? null;
  }
  return header;
}

function headerFromRpc(block: Record<string, unknown>): BlockHeader {
  const header: BlockHeader = {};
  for (const name of Object.values(HEADER_COLUMNS)) {
    const value = block[name];
    header[name] = value === undefined || value === null ? null : String(value);
  }
  return header;
}

const HEADER_WAIT_MS = 5_000;
const HEADER_WAIT_TRIES = 120;
const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * A header read from inside the chain's reorg window could be of a block that
 * is later replaced, with nothing to correct what the handler stored. The
 * translator holds the chain back by the reorg depth, so this is a backstop:
 * if HyperSync's head says the block is still too close, wait for it.
 */
function belowReorgWindow(chainId: number, blockNumber: number, archiveHeight?: number) {
  const lag = headerLag[chainId] ?? 0;
  return lag === 0 || archiveHeight === undefined || blockNumber <= archiveHeight - lag;
}

const headers = makeBatcher<BlockHeader>(
  "header",
  async (chainId, from, to) => {
    for (let attempt = 0; ; attempt++) {
      const fetched = await hyperSyncBlocks(
        chainId,
        from,
        to,
        Object.keys(HEADER_COLUMNS),
        headerFromHyperSync,
        "headers",
      );
      if (belowReorgWindow(chainId, to, fetched.archiveHeight)) return fetched;
      if (attempt >= HEADER_WAIT_TRIES) {
        throw new Error(
          `Envio Subgraph won't serve the header of block ${to} on chain ${chainId} yet: it is within ` +
            `${headerLag[chainId]} blocks of the head (${fetched.archiveHeight}), where a reorg could replace it.`,
        );
      }
      await sleep(HEADER_WAIT_MS);
    }
  },
  async (_chainId, blockNumber) => {
    if (rpcUrls.length === 0) {
      throw new Error(
        `Envio Subgraph couldn't read the header of block ${blockNumber}: HyperSync didn't\n` +
          `return it, and no RPC fallback is configured. Set ENVIO_SUBGRAPH_RPC in .env or the\n` +
          `environment.`,
      );
    }
    const client = rpcClient(rpcUrls);
    const block = await untilAnswered(
      `block ${blockNumber} from RPC`,
      () => client.getBlock({ blockNumber }),
      { deadline: false },
    );
    return headerFromRpc(block);
  },
);

export function requestBlockHeader(chainId: number, blockNumber: number): Promise<BlockHeader> {
  return headers.request(chainId, blockNumber);
}
