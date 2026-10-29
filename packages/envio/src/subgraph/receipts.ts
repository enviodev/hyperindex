/**
 * `event.receipt.logs`: every log of the event's transaction.
 *
 * envio hands a handler the event and, for a `receipt: true` handler, the
 * receipt's scalar fields as transaction fields — but not the other logs of the
 * transaction. They are read from HyperSync: the logs of the event's block, of
 * which the transaction's are kept. Every handler invocation in a batch asks
 * within the same microtask, so one query answers every transaction of a block,
 * and blocks run side by side. A chain HyperSync doesn't serve, or a failing
 * HyperSync, falls back to `eth_getTransactionReceipt` when an RPC is set.
 */

import { rpcClient } from "./rpc.ts";
import { HttpStatusError, untilAnswered, withDeadline } from "./transient.ts";

const API_TOKEN_ENV_VAR = "ENVIO_API_TOKEN";
const MAX_QUERIES_IN_FLIGHT = 8;
/** Blocks whose logs are kept for the transactions that ask later. */
const KEEP_BLOCKS = 128;

const hypersyncUrl = (chainId: number) => `https://${chainId}.hypersync.xyz/query`;

/** A log as the runtime serves it: hex strings, plain numbers. */
export type ReceiptLog = {
  address: string;
  topics: string[];
  data: string;
  logIndex: number;
  transactionIndex: number;
  transactionHash: string;
};

export type ReceiptRequest = { chainId: number; blockNumber: number; transactionIndex: number; transactionHash: string };

let rpcUrls: string[] = [];
/** Chains HyperSync doesn't serve, which RPC answers alone. */
let rpcOnly = new Set<number>();
/** Logs of recently read blocks, by chain then number; insertion order is age. */
let recent = new Map<string, Promise<ReceiptLog[]>>();
let inFlight = 0;
const queued: (() => void)[] = [];

export function configureReceiptLogs(urls: string[], rpcOnlyChains: number[] = []) {
  rpcUrls = urls;
  rpcOnly = new Set(rpcOnlyChains);
  recent = new Map();
}

async function slot<T>(run: () => Promise<T>): Promise<T> {
  if (inFlight >= MAX_QUERIES_IN_FLIGHT) await new Promise<void>((resolve) => queued.push(resolve));
  else inFlight++;
  try {
    return await run();
  } finally {
    const next = queued.shift();
    if (next) next();
    else inFlight--;
  }
}

type HyperSyncLogs = {
  data: { logs?: Record<string, string | number | null>[] }[];
  next_block: number;
};

const num = (value: unknown) => Number(value);

async function blockLogsFromHyperSync(chainId: number, blockNumber: number): Promise<ReceiptLog[]> {
  const token = process.env[API_TOKEN_ENV_VAR];
  const url = hypersyncUrl(chainId);
  const logs: ReceiptLog[] = [];
  let cursor = blockNumber;
  // A block is answered whole, but resume if the response says otherwise.
  while (cursor <= blockNumber) {
    const from = cursor;
    const ask = rpcUrls.length > 0 ? withDeadline : untilAnswered;
    const body = await ask(
      `HyperSync's logs of block ${blockNumber}`,
      async (signal): Promise<HyperSyncLogs> => {
        const response = await fetch(url, {
          method: "POST",
          signal,
          headers: {
            "content-type": "application/json",
            ...(token ? { authorization: `Bearer ${token}` } : {}),
          },
          body: JSON.stringify({
            from_block: from,
            to_block: blockNumber + 1,
            logs: [{}],
            field_selection: {
              log: [
                "block_number",
                "log_index",
                "transaction_index",
                "transaction_hash",
                "address",
                "data",
                "topic0",
                "topic1",
                "topic2",
                "topic3",
              ],
            },
          }),
        });
        if (!response.ok) {
          throw new HttpStatusError(url, response.status, await response.text());
        }
        return (await response.json()) as HyperSyncLogs;
      },
    );
    for (const page of body.data ?? []) {
      for (const log of page.logs ?? []) {
        if (num(log.block_number) !== blockNumber) continue;
        logs.push({
          address: String(log.address),
          topics: [log.topic0, log.topic1, log.topic2, log.topic3].filter(
            (topic): topic is string => typeof topic === "string",
          ),
          data: String(log.data ?? "0x"),
          logIndex: num(log.log_index),
          transactionIndex: num(log.transaction_index),
          transactionHash: String(log.transaction_hash),
        });
      }
    }
    if (!body.next_block || body.next_block <= cursor) break;
    cursor = body.next_block;
  }
  return logs.sort((a, b) => a.logIndex - b.logIndex);
}

function blockLogs(chainId: number, blockNumber: number): Promise<ReceiptLog[]> {
  const key = `${chainId}:${blockNumber}`;
  let logs = recent.get(key);
  if (!logs) {
    logs = slot(() => blockLogsFromHyperSync(chainId, blockNumber));
    recent.set(key, logs);
    // A failed read is not kept: the retry should ask again.
    logs.catch(() => recent.delete(key));
    if (recent.size > KEEP_BLOCKS) recent.delete(recent.keys().next().value as string);
  }
  return logs;
}

async function fromRpc(request: ReceiptRequest): Promise<ReceiptLog[]> {
  const client = rpcClient(rpcUrls);
  const receipt = await untilAnswered(
    `the receipt of ${request.transactionHash} from RPC`,
    () => client.getTransactionReceipt({ hash: request.transactionHash }),
    { deadline: false },
  );
  return (receipt.logs as Record<string, any>[]).map((log) => ({
    address: log.address,
    topics: [...log.topics],
    data: log.data,
    logIndex: Number(log.logIndex),
    transactionIndex: Number(log.transactionIndex),
    transactionHash: log.transactionHash,
  }));
}

/** The logs of one transaction, in log order. */
export async function requestReceiptLogs(request: ReceiptRequest): Promise<ReceiptLog[]> {
  if (rpcOnly.has(request.chainId) && rpcUrls.length > 0) return fromRpc(request);
  try {
    const logs = await blockLogs(request.chainId, request.blockNumber);
    const mine = logs.filter((log) => log.transactionIndex === request.transactionIndex);
    // An event of this transaction has to be among them; if not, HyperSync
    // is behind or answered another fork, and RPC is asked instead.
    if (mine.length > 0 || rpcUrls.length === 0) return mine;
  } catch (error) {
    if (rpcUrls.length === 0) {
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(
        `Envio Subgraph couldn't read the logs of transaction ${request.transactionHash} from HyperSync: ${message}\n` +
          `Set ${API_TOKEN_ENV_VAR} in .env or the environment — create one at\n` +
          `https://envio.dev/app/api-tokens — or set ENVIO_SUBGRAPH_RPC to fall back to RPC.`,
      );
    }
  }
  return fromRpc(request);
}
