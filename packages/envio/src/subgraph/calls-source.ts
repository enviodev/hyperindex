/**
 * Reads the calls a subgraph's call handlers and `filter: call` block handlers
 * run on, the way graph-node does (`chain/ethereum`): every successful call
 * (CALL, STATICCALL, DELEGATECALL, CALLCODE — top level and internal) to a data
 * source's address whose input is at least a selector long, from a transaction
 * that succeeded.
 *
 * Two backends serve the same page: HyperSync's trace endpoint (Ethereum,
 * Gnosis, Base, Arbitrum, Monad) and a node's `trace_filter` or
 * `debug_traceBlockByNumber`. `CallSource.res` wraps a chain's log source and
 * asks `fetchCalls` for the same block range; the calls come back as the event
 * items they travel as through the rest of envio.
 */

import { rpcClient } from "./rpc.ts";
import { HttpStatusError, untilAnswered } from "./transient.ts";
import { warn } from "./log.ts";

/** The chains HyperSync serves traces for, at `<chainId>-traces.hypersync.xyz`. */
export const HYPERSYNC_TRACE_CHAINS = new Set([1, 100, 143, 8453, 42161]);

export type CallRegistration = {
  /** The chain's registration index, echoed back on each item. */
  index: number;
  contractName: string;
  eventName: string;
  /** The function's 4-byte selector as `0x…`; `null` for a block handler, which wants every call. */
  selector: string | null;
  /** 1 for a call handler, 2 for a `filter: call` block handler. */
  rank: 1 | 2;
  isWildcard: boolean;
  startBlock: number | null;
};

export type CallRequest = {
  chainId: number;
  /** Inclusive. */
  fromBlock: number;
  /** Inclusive. */
  toBlock: number;
  registrations: CallRegistration[];
  /** Lowercase addresses the partition holds, by contract name. */
  addresses: Record<string, string[]>;
  rpcUrls: string[];
};

export type CallItem = {
  registrationIndex: number;
  blockNumber: number;
  transactionIndex: number;
  /** The call's position in its transaction's trace tree. */
  traceAddress: number[];
  payload: Record<string, unknown>;
};

export type CallResponse = {
  items: CallItem[];
  /** The last block the answer covers: every call up to it is in `items`. */
  latestFetchedBlockNumber: number;
  /** The hash and time of each block a call was in, for reorg detection. */
  blocks: { blockNumber: number; blockHash: string; blockTimestamp: number }[];
  knownHeight: number | null;
};

/** One call as a backend reports it, before any handler's filter. */
export type RawCall = {
  blockNumber: number;
  transactionIndex: number;
  traceAddress: number[];
  callType: string;
  from: string;
  to: string;
  input: string;
  output: string;
  value: bigint;
  gasUsed: bigint;
  error: boolean;
};

type TxInfo = Record<string, unknown> & { status: number | null };
type BlockInfo = Record<string, unknown> & { number: number; hash: string; timestamp: number };

type TracePage = {
  calls: RawCall[];
  blocks: Map<number, BlockInfo>;
  transactions: Map<string, TxInfo>;
  latestFetchedBlockNumber: number;
  knownHeight: number | null;
};

/** What a backend can narrow its search by; the exact match is made here. */
type Selection = { addresses: string[]; selectors: string[] | null };

type Backend = {
  name: string;
  page(request: CallRequest, selections: Selection[]): Promise<TracePage>;
};

export const txKey = (blockNumber: number, transactionIndex: number) => `${blockNumber}:${transactionIndex}`;

const hexToBigInt = (value: unknown): bigint =>
  value === null || value === undefined ? 0n : BigInt(value as string | number | bigint);

const lower = (value: unknown): string => String(value ?? "").toLowerCase();

/** HyperSync packs a trace address as a little-endian u64 length, then that many u64s. */
export function parseHyperSyncTraceAddress(packed: string): number[] {
  const bytes = Buffer.from(packed.replace(/^0x/, ""), "hex");
  const length = Number(bytes.readBigUInt64LE(0));
  const address: number[] = [];
  for (let i = 0; i < length; i++) address.push(Number(bytes.readBigUInt64LE(8 + 8 * i)));
  return address;
}

/** Pre-order of a trace tree is lexicographic order of the addresses, a prefix first. */
export function compareTraceAddress(a: number[], b: number[]): number {
  const shared = Math.min(a.length, b.length);
  for (let i = 0; i < shared; i++) if (a[i] !== b[i]) return a[i] - b[i];
  return a.length - b.length;
}

// ---------------------------------------------------------------------------
// HyperSync
// ---------------------------------------------------------------------------

const hyperSyncUrl = (chainId: number) =>
  (process.env.ENVIO_SUBGRAPH_TRACES_URL ?? "https://{chainId}-traces.hypersync.xyz").replace(
    "{chainId}",
    String(chainId),
  );

const ADDRESSES_PER_SELECTION = 2_000;

function hyperSyncBackend(): Backend {
  return {
    name: "HyperSync traces",
    async page(request, selections) {
      const token = process.env.ENVIO_API_TOKEN;
      const traces: Record<string, unknown>[] = [];
      for (const selection of selections) {
        for (let i = 0; i < selection.addresses.length; i += ADDRESSES_PER_SELECTION) {
          traces.push({
            to: selection.addresses.slice(i, i + ADDRESSES_PER_SELECTION),
            type: ["call"],
            ...(selection.selectors ? { sighash: selection.selectors } : {}),
          });
        }
      }
      const body = JSON.stringify({
        from_block: request.fromBlock,
        to_block: request.toBlock + 1,
        // Joins the matched traces' transactions, which the default does not.
        join_mode: "JoinAll",
        traces,
        field_selection: {
          trace: [
            "block_number",
            "transaction_position",
            "trace_address",
            "type",
            "call_type",
            "from",
            "to",
            "input",
            "output",
            "error",
            "gas_used",
            "value",
          ],
          transaction: [
            "block_number",
            "transaction_index",
            "hash",
            "from",
            "to",
            "value",
            "gas",
            "gas_price",
            "input",
            "nonce",
            "status",
          ],
          block: [
            "number",
            "hash",
            "parent_hash",
            "sha3_uncles",
            "miner",
            "state_root",
            "transactions_root",
            "receipts_root",
            "gas_used",
            "gas_limit",
            "timestamp",
            "difficulty",
            "total_difficulty",
            "size",
            "base_fee_per_gas",
          ],
        },
      });
      const url = `${hyperSyncUrl(request.chainId)}/query`;
      const response: any = await untilAnswered("The HyperSync traces request", async (signal) => {
        const res = await fetch(url, {
          method: "POST",
          headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
          body,
          signal,
        });
        if (!res.ok) {
          const detail = (await res.text()).slice(0, 300);
          throw new HttpStatusError(url, res.status, detail || res.statusText);
        }
        return res.json();
      });

      const calls: RawCall[] = [];
      const blocks = new Map<number, BlockInfo>();
      const transactions = new Map<string, TxInfo>();
      for (const page of response.data ?? []) {
        for (const trace of page.traces ?? []) {
          calls.push({
            blockNumber: trace.block_number,
            transactionIndex: trace.transaction_position,
            traceAddress: parseHyperSyncTraceAddress(trace.trace_address),
            callType: trace.call_type ?? "call",
            from: lower(trace.from),
            to: lower(trace.to),
            input: lower(trace.input),
            output: lower(trace.output ?? "0x"),
            value: hexToBigInt(trace.value),
            gasUsed: hexToBigInt(trace.gas_used),
            error: trace.error !== null && trace.error !== undefined,
          });
        }
        for (const block of page.blocks ?? []) {
          blocks.set(block.number, {
            number: block.number,
            hash: block.hash,
            parentHash: block.parent_hash,
            sha3Uncles: block.sha3_uncles,
            miner: lower(block.miner),
            stateRoot: block.state_root,
            transactionsRoot: block.transactions_root,
            receiptsRoot: block.receipts_root,
            gasUsed: hexToBigInt(block.gas_used),
            gasLimit: hexToBigInt(block.gas_limit),
            timestamp: Number(hexToBigInt(block.timestamp)),
            difficulty: block.difficulty === undefined ? null : hexToBigInt(block.difficulty),
            totalDifficulty: block.total_difficulty === undefined ? null : hexToBigInt(block.total_difficulty),
            size: block.size === undefined ? null : hexToBigInt(block.size),
            baseFeePerGas: block.base_fee_per_gas === undefined ? null : hexToBigInt(block.base_fee_per_gas),
          });
        }
        for (const tx of page.transactions ?? []) {
          transactions.set(txKey(tx.block_number, tx.transaction_index), {
            hash: tx.hash,
            transactionIndex: tx.transaction_index,
            from: lower(tx.from),
            to: tx.to ? lower(tx.to) : null,
            value: hexToBigInt(tx.value),
            gas: hexToBigInt(tx.gas),
            gasPrice: tx.gas_price === undefined ? null : hexToBigInt(tx.gas_price),
            input: tx.input,
            nonce: hexToBigInt(tx.nonce),
            status: tx.status ?? null,
          });
        }
      }
      return {
        calls,
        blocks,
        transactions,
        // `next_block` is the first block the answer does not cover.
        latestFetchedBlockNumber: Math.min(request.toBlock, Number(response.next_block) - 1),
        knownHeight: response.archive_height ?? null,
      };
    },
  };
}

// ---------------------------------------------------------------------------
// RPC
// ---------------------------------------------------------------------------

const toHex = (n: number) => `0x${n.toString(16)}`;

function positive(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : fallback;
}

type RpcRequest = (method: string, params: unknown[], options?: { maxTries?: number }) => Promise<any>;

function makeRpcRequest(rpcUrls: string[]): RpcRequest {
  if (rpcUrls.length === 0) {
    throw new Error(
      "Envio Subgraph needs an RPC endpoint to read this chain's calls: HyperSync serves traces " +
        "for Ethereum, Gnosis, Base, Arbitrum and Monad only. Set ENVIO_SUBGRAPH_RPC to an archive " +
        "node that serves trace_filter or debug_traceBlockByNumber.",
    );
  }
  const client = rpcClient(rpcUrls);
  return (method, params, options) =>
    untilAnswered(`The ${method} request`, () => client.request({ method, params }), {
      deadline: false,
      ...options,
    });
}

/**
 * The block, and the transactions at `wanted` positions, an RPC call trigger
 * carries. Some endpoints answer `eth_getBlockByNumber(…, true)` with no
 * transactions at all (BNB Chain's, through dRPC), so the block comes as hashes
 * and each transaction a handler needs is read by its own hash.
 */
async function blockAndTransactions(request: RpcRequest, blockNumber: number, wanted: Set<number>) {
  const raw = await request("eth_getBlockByNumber", [toHex(blockNumber), false]);
  if (!raw) throw new Error(`The RPC node has no block ${blockNumber}.`);
  const block: BlockInfo = {
    number: blockNumber,
    hash: raw.hash,
    parentHash: raw.parentHash,
    sha3Uncles: raw.sha3Uncles,
    miner: lower(raw.miner),
    stateRoot: raw.stateRoot,
    transactionsRoot: raw.transactionsRoot,
    receiptsRoot: raw.receiptsRoot,
    gasUsed: hexToBigInt(raw.gasUsed),
    gasLimit: hexToBigInt(raw.gasLimit),
    timestamp: Number(hexToBigInt(raw.timestamp)),
    difficulty: raw.difficulty === undefined ? null : hexToBigInt(raw.difficulty),
    totalDifficulty: raw.totalDifficulty === undefined ? null : hexToBigInt(raw.totalDifficulty),
    size: raw.size === undefined ? null : hexToBigInt(raw.size),
    baseFeePerGas: raw.baseFeePerGas === undefined ? null : hexToBigInt(raw.baseFeePerGas),
  };
  const transactions = new Map<string, TxInfo>();
  await Promise.all(
    [...wanted].map(async (transactionIndex) => {
      const entry = raw.transactions[transactionIndex];
      const tx = typeof entry === "string" ? await request("eth_getTransactionByHash", [entry]) : entry;
      if (!tx) throw new Error(`The RPC node has no transaction ${transactionIndex} in block ${blockNumber}.`);
      transactions.set(txKey(blockNumber, transactionIndex), {
        hash: tx.hash,
        transactionIndex,
        from: lower(tx.from),
        to: tx.to ? lower(tx.to) : null,
        value: hexToBigInt(tx.value),
        gas: hexToBigInt(tx.gas),
        gasPrice: tx.gasPrice === undefined ? null : hexToBigInt(tx.gasPrice),
        input: tx.input,
        nonce: hexToBigInt(tx.nonce),
        status: null,
      });
    }),
  );
  return { block, transactions };
}

/** Receipt statuses for a block's transactions: `eth_getBlockReceipts`, else one receipt each. */
async function fillStatuses(request: RpcRequest, blockNumber: number, transactions: Map<string, TxInfo>) {
  let receipts: any[] | null = null;
  try {
    receipts = await request("eth_getBlockReceipts", [toHex(blockNumber)], { maxTries: 2 });
  } catch {
    receipts = null;
  }
  if (receipts) {
    for (const receipt of receipts) {
      const tx = transactions.get(txKey(blockNumber, Number(receipt.transactionIndex)));
      if (tx) tx.status = receipt.status === undefined ? null : Number(receipt.status);
    }
    return;
  }
  await Promise.all(
    [...transactions.entries()]
      .filter(([key]) => key.startsWith(`${blockNumber}:`))
      .map(async ([, tx]) => {
        const receipt = await request("eth_getTransactionReceipt", [tx.hash]);
        tx.status = receipt?.status === undefined ? null : Number(receipt.status);
      }),
  );
}

/** A parity-format trace (`trace_filter`) as a call, or null for anything but a CALL. */
export function callOfParityTrace(trace: any): RawCall | null {
  if (trace.type !== "call" || trace.action?.input === undefined) return null;
  if (trace.transactionPosition === null || trace.transactionPosition === undefined) return null;
  return {
    blockNumber: Number(trace.blockNumber),
    transactionIndex: Number(trace.transactionPosition),
    traceAddress: (trace.traceAddress ?? []).map(Number),
    callType: String(trace.action.callType ?? "call").toLowerCase(),
    from: lower(trace.action.from),
    to: lower(trace.action.to),
    input: lower(trace.action.input),
    output: lower(trace.result?.output ?? "0x"),
    value: hexToBigInt(trace.action.value),
    gasUsed: hexToBigInt(trace.result?.gasUsed),
    error: trace.error !== undefined && trace.error !== null,
  };
}

const CALL_TYPES = new Set(["CALL", "STATICCALL", "DELEGATECALL", "CALLCODE"]);

/** Flattens `debug_traceBlockByNumber`'s callTracer trees into calls, in trace order. */
export function callsOfCallTracer(blockNumber: number, traced: any[]): { calls: RawCall[]; topLevelFailed: Set<number> } {
  const calls: RawCall[] = [];
  const topLevelFailed = new Set<number>();
  traced.forEach((entry, transactionIndex) => {
    const root = entry?.result ?? entry;
    if (!root) return;
    if (root.error) topLevelFailed.add(transactionIndex);
    const walk = (frame: any, traceAddress: number[]) => {
      if (CALL_TYPES.has(String(frame.type ?? "CALL").toUpperCase()) && frame.to) {
        calls.push({
          blockNumber,
          transactionIndex,
          traceAddress,
          callType: String(frame.type ?? "CALL").toLowerCase(),
          from: lower(frame.from),
          to: lower(frame.to),
          input: lower(frame.input ?? "0x"),
          output: lower(frame.output ?? "0x"),
          value: hexToBigInt(frame.value),
          gasUsed: hexToBigInt(frame.gasUsed),
          error: frame.error !== undefined && frame.error !== null && frame.error !== "",
        });
      }
      (frame.calls ?? []).forEach((child: any, index: number) => walk(child, [...traceAddress, index]));
    };
    walk(root, []);
  });
  return { calls, topLevelFailed };
}

function rpcBackend(): Backend {
  // One mode per process once it is known: trace_filter where the node has it.
  let mode: "trace_filter" | "debug" | null =
    process.env.ENVIO_SUBGRAPH_TRACE_MODE === "debug"
      ? "debug"
      : process.env.ENVIO_SUBGRAPH_TRACE_MODE === "trace_filter"
        ? "trace_filter"
        : null;

  const viaTraceFilter = async (
    request: CallRequest,
    selections: Selection[],
    rpc: RpcRequest,
    options?: { maxTries?: number; span?: number },
  ) => {
    const span = options?.span ?? positive("ENVIO_SUBGRAPH_TRACE_FILTER_BLOCKS", 500);
    const toBlock = Math.min(request.toBlock, request.fromBlock + span - 1);
    const anyAddress = selections.some((selection) => selection.addresses.length === 0);
    const addresses = [...new Set(selections.flatMap((selection) => selection.addresses))];
    const traces: any[] = await rpc(
      "trace_filter",
      [
        {
          fromBlock: toHex(request.fromBlock),
          toBlock: toHex(toBlock),
          ...(anyAddress ? {} : { toAddress: addresses }),
        },
      ],
      options,
    );
    const calls = traces.map(callOfParityTrace).filter((call): call is RawCall => call !== null);
    return { calls, toBlock, topLevelFailed: new Map<number, Set<number>>() };
  };

  const viaDebugTrace = async (request: CallRequest, rpc: RpcRequest) => {
    const span = positive("ENVIO_SUBGRAPH_TRACE_BLOCKS_PER_PAGE", 25);
    const toBlock = Math.min(request.toBlock, request.fromBlock + span - 1);
    const calls: RawCall[] = [];
    const topLevelFailed = new Map<number, Set<number>>();
    const blocks = Array.from({ length: toBlock - request.fromBlock + 1 }, (_, i) => request.fromBlock + i);
    const concurrency = positive("ENVIO_SUBGRAPH_TRACE_CONCURRENCY", 4);
    let next = 0;
    await Promise.all(
      Array.from({ length: Math.min(concurrency, blocks.length) }, async () => {
        while (next < blocks.length) {
          const blockNumber = blocks[next++];
          const traced: any[] = await rpc("debug_traceBlockByNumber", [toHex(blockNumber), { tracer: "callTracer" }]);
          const flat = callsOfCallTracer(blockNumber, traced);
          calls.push(...flat.calls);
          topLevelFailed.set(blockNumber, flat.topLevelFailed);
        }
      }),
    );
    return { calls, toBlock, topLevelFailed };
  };

  return {
    name: "RPC traces",
    async page(request, selections) {
      const rpc = makeRpcRequest(request.rpcUrls);
      let result: { calls: RawCall[]; toBlock: number; topLevelFailed: Map<number, Set<number>> };
      if (mode === "debug") result = await viaDebugTrace(request, rpc);
      else if (mode === "trace_filter") result = await viaTraceFilter(request, selections, rpc);
      else {
        try {
          // A node without trace_filter answers every try alike — or, for an address filter over
          // old blocks, doesn't answer — so this probe is short and doesn't wait out a rate limit.
          result = await viaTraceFilter(request, selections, rpc, { maxTries: 2, span: 10 });
          mode = "trace_filter";
        } catch (error) {
          warn(
            `Envio Subgraph: the RPC node doesn't serve trace_filter (${String(error).split("\n")[0]}); ` +
              "reading calls with debug_traceBlockByNumber, one block at a time.",
          );
          mode = "debug";
          result = await viaDebugTrace(request, rpc);
        }
      }

      // Only blocks holding a call a handler wants need their body and receipts.
      const watched = watchedRegistrations(request);
      result.calls = result.calls.filter((call) => watched(call).length > 0);
      const wanted = new Map<number, Set<number>>();
      for (const call of result.calls) {
        const positions = wanted.get(call.blockNumber) ?? new Set<number>();
        positions.add(call.transactionIndex);
        wanted.set(call.blockNumber, positions);
      }
      const blocks = new Map<number, BlockInfo>();
      const transactions = new Map<string, TxInfo>();
      await Promise.all(
        [...wanted].map(async ([blockNumber, positions]) => {
          const body = await blockAndTransactions(rpc, blockNumber, positions);
          await fillStatuses(rpc, blockNumber, body.transactions);
          blocks.set(blockNumber, body.block);
          for (const [key, tx] of body.transactions) transactions.set(key, tx);
        }),
      );
      // A transaction whose own top-level call failed has failed whatever its receipt.
      for (const [blockNumber, failed] of result.topLevelFailed) {
        for (const transactionIndex of failed) {
          const tx = transactions.get(txKey(blockNumber, transactionIndex));
          if (tx) tx.status = 0;
        }
      }
      return {
        calls: result.calls,
        blocks,
        transactions,
        latestFetchedBlockNumber: result.toBlock,
        knownHeight: null,
      };
    },
  };
}

// ---------------------------------------------------------------------------
// Matching: graph-node's call filter and trigger rules
// ---------------------------------------------------------------------------

/**
 * `EthereumCallFilter::matches` and `parse_call_triggers`: a call to an
 * address a handler watches, with input of a selector or more, that did not
 * itself fail and — for a call handler — whose transaction succeeded. A block
 * handler's `WithCallTo` trigger takes every such call; it is not held to the
 * transaction's status.
 */
/** The registrations a call is a trigger for, before its transaction's status is known. */
export function watchedRegistrations(request: CallRequest): (call: RawCall) => CallRegistration[] {
  const owned = new Map<string, Set<string>>();
  for (const [contract, addresses] of Object.entries(request.addresses)) owned.set(contract, new Set(addresses));
  return (call) => {
    if (call.error || (call.input.length - 2) / 2 < 4) return [];
    const selector = call.input.slice(0, 10);
    return request.registrations.filter(
      (registration) =>
        (registration.startBlock === null || call.blockNumber >= registration.startBlock) &&
        (registration.isWildcard || owned.get(registration.contractName)?.has(call.to)) &&
        (registration.rank === 2 || registration.selector === selector),
    );
  };
}

export function buildItems(request: CallRequest, page: TracePage): CallItem[] {
  const items: CallItem[] = [];
  const calls = page.calls
    .filter((call) => call.blockNumber >= request.fromBlock && call.blockNumber <= page.latestFetchedBlockNumber)
    .sort(
      (a, b) =>
        a.blockNumber - b.blockNumber ||
        a.transactionIndex - b.transactionIndex ||
        compareTraceAddress(a.traceAddress, b.traceAddress),
    );
  const watched = watchedRegistrations(request);

  for (const call of calls) {
    for (const registration of watched(call)) {
      const transaction = page.transactions.get(txKey(call.blockNumber, call.transactionIndex));
      const block = page.blocks.get(call.blockNumber);
      if (!transaction || !block) {
        throw new Error(
          `The ${request.chainId} trace backend returned a call in block ${call.blockNumber} ` +
            `(transaction ${call.transactionIndex}) without that ${transaction ? "block" : "transaction"}.`,
        );
      }
      if (registration.rank === 1 && transaction.status === 0) continue;

      const { status: _status, ...transactionFields } = transaction;
      items.push({
        registrationIndex: registration.index,
        blockNumber: call.blockNumber,
        transactionIndex: call.transactionIndex,
        traceAddress: call.traceAddress,
        payload: {
          contractName: registration.contractName,
          eventName: registration.eventName,
          params: {
            callInput: call.input,
            callOutput: call.output,
            callFrom: call.from,
            callValue: call.value,
            callGasUsed: call.gasUsed,
          },
          chainId: request.chainId,
          srcAddress: call.to,
          logIndex: 0,
          transaction: transactionFields,
          block,
        },
      });
    }
  }
  return items;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

const backends = new Map<number, Promise<Backend>>();

/** HyperSync where its trace endpoint answers for the chain, else the node. */
async function backendFor(chainId: number): Promise<Backend> {
  const forced = process.env.ENVIO_SUBGRAPH_TRACE_MODE;
  if (forced === "debug" || forced === "trace_filter") return rpcBackend();
  if (forced === "hypersync") return hyperSyncBackend();
  const known = HYPERSYNC_TRACE_CHAINS.has(chainId) || process.env.ENVIO_SUBGRAPH_TRACES_URL !== undefined;
  return known ? hyperSyncBackend() : rpcBackend();
}

export function resetCallBackends() {
  backends.clear();
}

export async function fetchCalls(request: CallRequest): Promise<CallResponse> {
  let backend = backends.get(request.chainId);
  if (!backend) {
    backend = backendFor(request.chainId);
    backends.set(request.chainId, backend);
  }
  const resolved = await backend;

  // One search per contract: its addresses, narrowed to the selectors of its
  // call handlers unless a block handler watches every call.
  const selections: Selection[] = [];
  const contracts = new Set(request.registrations.map((registration) => registration.contractName));
  for (const contract of contracts) {
    const registrations = request.registrations.filter((registration) => registration.contractName === contract);
    const wildcard = registrations.some((registration) => registration.isWildcard);
    const addresses = request.addresses[contract] ?? [];
    if (addresses.length === 0 && !wildcard) continue;
    const everything = registrations.some((registration) => registration.rank === 2);
    selections.push({
      addresses: wildcard ? [] : addresses,
      selectors: everything
        ? null
        : [...new Set(registrations.map((registration) => registration.selector as string))],
    });
  }
  if (selections.length === 0) {
    return { items: [], latestFetchedBlockNumber: request.toBlock, blocks: [], knownHeight: null };
  }

  const page = await resolved.page(request, selections);
  if (page.latestFetchedBlockNumber < request.fromBlock) {
    throw new Error(
      `${resolved.name} for chain ${request.chainId} has not reached block ${request.fromBlock} yet ` +
        `(it answered through ${page.latestFetchedBlockNumber}).`,
    );
  }
  const items = buildItems(request, page);
  const seen = new Set<number>();
  const blocks = [];
  for (const item of items) {
    if (seen.has(item.blockNumber)) continue;
    seen.add(item.blockNumber);
    const block = page.blocks.get(item.blockNumber)!;
    blocks.push({ blockNumber: item.blockNumber, blockHash: block.hash, blockTimestamp: block.timestamp });
  }
  return {
    items,
    latestFetchedBlockNumber: page.latestFetchedBlockNumber,
    blocks,
    knownHeight: page.knownHeight,
  };
}
