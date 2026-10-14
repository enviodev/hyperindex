import { afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import http from "node:http";
import type { AddressInfo } from "node:net";
import type {
  CallRegistration,
  CallRequest,
} from "envio/src/subgraph/calls-source.ts";

// envio's own TypeScript is loaded through the hooks `envio start` registers.
type Calls = typeof import("envio/src/subgraph/calls-source.ts");
let calls: Calls;
beforeAll(async () => {
  const { registerTsHooks } = await import("envio/src/HandlerLoader.res.mjs");
  registerTsHooks();
  calls = await import("envio/src/subgraph/calls-source.ts");
});
const fetchCalls: Calls["fetchCalls"] = (request) => calls.fetchCalls(request);
const resetCallBackends = () => calls.resetCallBackends();
const parseHyperSyncTraceAddress = (packed: string) => calls.parseHyperSyncTraceAddress(packed);
const compareTraceAddress = (a: number[], b: number[]) => calls.compareTraceAddress(a, b);
const callOfParityTrace = (trace: unknown) => calls.callOfParityTrace(trace);
const callsOfCallTracer = (block: number, traced: unknown[]) => calls.callsOfCallTracer(block, traced);

const staking = "0x1111111111111111111111111111111111111111";
const other = "0x2222222222222222222222222222222222222222";
const user = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const stakeSelector = "0xa694fc3a";
const stakeInput = stakeSelector + "00".repeat(31) + "05";
const output = "0x" + "00".repeat(31) + "09";

const stakeHandler: CallRegistration = {
  index: 3,
  contractName: "Staking",
  eventName: "__envio_call_a694fc3a_stake",
  selector: stakeSelector,
  rank: 1,
  isWildcard: false,
  startBlock: null,
};
const blockHandler: CallRegistration = {
  index: 4,
  contractName: "Staking",
  eventName: "__envio_call_any",
  selector: null,
  rank: 2,
  isWildcard: false,
  startBlock: null,
};

const request = (over: Partial<CallRequest> = {}): CallRequest => ({
  chainId: 31337,
  fromBlock: 100,
  toBlock: 200,
  registrations: [stakeHandler],
  addresses: { Staking: [staking] },
  rpcUrls: [],
  ...over,
});

/** A trace address the way HyperSync packs it: u64 length, then u64 entries, little endian. */
const packed = (address: number[]) => {
  const bytes = Buffer.alloc(8 + 8 * address.length);
  bytes.writeBigUInt64LE(BigInt(address.length), 0);
  address.forEach((entry, i) => bytes.writeBigUInt64LE(BigInt(entry), 8 + 8 * i));
  return "0x" + bytes.toString("hex");
};

const trace = (over: Record<string, unknown>) => ({
  block_number: 110,
  transaction_position: 0,
  trace_address: packed([]),
  type: "call",
  call_type: "call",
  from: user,
  to: staking,
  input: stakeInput,
  output,
  value: "0x00",
  gas_used: "0x5208",
  ...over,
});

const block = (number: number) => ({
  number,
  hash: "0x" + number.toString(16).padStart(64, "0"),
  parent_hash: "0x" + "00".repeat(32),
  miner: "0x" + "bb".repeat(20),
  gas_used: "0x10",
  gas_limit: "0x20",
  timestamp: "0x" + (1_000 + number).toString(16),
});

const tx = (blockNumber: number, index: number, status: number | null = 1) => ({
  block_number: blockNumber,
  transaction_index: index,
  hash: "0x" + blockNumber.toString(16).padStart(32, "0") + index.toString(16).padStart(32, "0"),
  from: user,
  to: staking,
  value: "0x00",
  gas: "0x5208",
  gas_price: "0x01",
  input: stakeInput,
  nonce: "0x07",
  status,
});

type Handler = (body: any, url: string) => { status?: number; body: unknown };
let server: http.Server;
let handler: Handler;
let requests: { url: string; body: any }[] = [];

beforeEach(async () => {
  requests = [];
  server = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => (raw += chunk));
    req.on("end", () => {
      const body = raw ? JSON.parse(raw) : null;
      requests.push({ url: req.url ?? "", body });
      const answer = handler(body, req.url ?? "");
      res.writeHead(answer.status ?? 200, { "content-type": "application/json" });
      res.end(JSON.stringify(answer.body));
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  resetCallBackends();
});

afterEach(async () => {
  delete process.env.ENVIO_SUBGRAPH_TRACES_URL;
  delete process.env.ENVIO_SUBGRAPH_TRACE_MODE;
  delete process.env.ENVIO_SUBGRAPH_RETRY_BACKOFF_MS;
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

const url = () => `http://127.0.0.1:${(server.address() as AddressInfo).port}`;

describe("trace addresses", () => {
  it("reads HyperSync's packed form and orders a trace tree depth first", () => {
    expect(
      [
        parseHyperSyncTraceAddress(packed([])),
        parseHyperSyncTraceAddress(packed([2])),
        parseHyperSyncTraceAddress(packed([0, 1, 3])),
      ],
    ).toEqual([[], [2], [0, 1, 3]]);
    const tree = [[1], [], [0, 1], [0], [0, 0, 5], [2]];
    expect(tree.sort(compareTraceAddress)).toEqual([[], [0], [0, 0, 5], [0, 1], [1], [2]]);
  });
});

describe("HyperSync traces", () => {
  beforeEach(() => {
    process.env.ENVIO_SUBGRAPH_TRACES_URL = "http://placeholder";
  });

  it("asks per contract for its addresses and selectors, and returns graph-node's triggers", async () => {
    handler = () => ({
      body: {
        archive_height: 5_000,
        next_block: 201,
        data: [
          {
            traces: [
              // Out of order on purpose: the order is the block's, then the trace tree's.
              trace({ block_number: 120, transaction_position: 2, trace_address: packed([1]) }),
              trace({ block_number: 120, transaction_position: 2, trace_address: packed([]) }),
              trace({ block_number: 110, transaction_position: 4, trace_address: packed([0, 2]) }),
              // The transaction reverted: a call handler skips it.
              trace({ block_number: 130, transaction_position: 0 }),
              // The call itself failed.
              trace({ block_number: 140, transaction_position: 0, error: "Reverted" }),
              // A transfer of value, no selector.
              trace({ block_number: 150, transaction_position: 0, input: "0x" }),
              // Another function of the same contract: not this handler's.
              trace({ block_number: 160, transaction_position: 0, input: "0x12345678" + "00".repeat(32) }),
              // A call to an address the partition does not hold.
              trace({ block_number: 170, transaction_position: 0, to: other }),
            ],
            transactions: [
              tx(110, 4),
              tx(120, 2),
              tx(130, 0, 0),
              tx(140, 0),
              tx(150, 0),
              tx(160, 0),
              tx(170, 0),
            ],
            blocks: [110, 120, 130, 140, 150, 160, 170].map(block),
          },
        ],
      },
    });
    process.env.ENVIO_SUBGRAPH_TRACES_URL = url();

    const response = await fetchCalls(request());

    expect(
      response.items.map((item) => [item.blockNumber, item.transactionIndex, item.traceAddress]),
    ).toEqual([
      [110, 4, [0, 2]],
      [120, 2, []],
      [120, 2, [1]],
    ]);
    expect(requests.map((r) => r.body)).toMatchObject([
      {
        from_block: 100,
        // HyperSync's range is half open.
        to_block: 201,
        join_mode: "JoinAll",
        traces: [{ to: [staking], type: ["call"], sighash: [stakeSelector] }],
      },
    ]);
    expect(response.latestFetchedBlockNumber).toBe(200);
    expect(response.knownHeight).toBe(5_000);
    expect(response.blocks.map((b) => b.blockNumber)).toEqual([110, 120]);

    const [first] = response.items;
    expect(first.registrationIndex).toBe(3);
    expect(first.payload).toMatchObject({
      contractName: "Staking",
      eventName: "__envio_call_a694fc3a_stake",
      chainId: 31337,
      srcAddress: staking,
      params: {
        callInput: stakeInput,
        callOutput: output,
        callFrom: user,
        callValue: 0n,
        callGasUsed: 0x5208n,
      },
      transaction: { transactionIndex: 4, from: user, nonce: 7n, gas: 0x5208n },
      block: { number: 110, timestamp: 1_110, gasUsed: 16n, miner: "0x" + "bb".repeat(20) },
    });
  });

  it("gives a block handler every call, whatever the function or the transaction's fate", async () => {
    handler = () => ({
      body: {
        archive_height: 1,
        next_block: 201,
        data: [
          {
            traces: [
              trace({ block_number: 130, transaction_position: 0 }),
              trace({ block_number: 160, transaction_position: 0, input: "0x12345678" + "00".repeat(32) }),
              trace({ block_number: 140, transaction_position: 0, error: "Reverted" }),
            ],
            transactions: [tx(130, 0, 0), tx(160, 0), tx(140, 0)],
            blocks: [130, 140, 160].map(block),
          },
        ],
      },
    });
    process.env.ENVIO_SUBGRAPH_TRACES_URL = url();

    const response = await fetchCalls(request({ registrations: [stakeHandler, blockHandler] }));

    expect(requests[0].body.traces).toEqual([{ to: [staking], type: ["call"] }]);
    expect(response.items.map((item) => [item.blockNumber, item.registrationIndex])).toEqual([
      [130, 4],
      [160, 4],
    ]);
  });

  it("stops where HyperSync stopped", async () => {
    handler = () => ({
      body: {
        archive_height: 9_000,
        next_block: 151,
        data: [{ traces: [trace({ block_number: 120 })], transactions: [tx(120, 0)], blocks: [block(120)] }],
      },
    });
    process.env.ENVIO_SUBGRAPH_TRACES_URL = url();
    const response = await fetchCalls(request());
    expect([response.items.length, response.latestFetchedBlockNumber]).toEqual([1, 150]);
  });

  it("skips a contract with no addresses to watch, and a call before its registration starts", async () => {
    handler = () => ({
      body: {
        archive_height: 1,
        next_block: 201,
        data: [
          {
            traces: [trace({ block_number: 120 }), trace({ block_number: 190 })],
            transactions: [tx(120, 0), tx(190, 0)],
            blocks: [120, 190].map(block),
          },
        ],
      },
    });
    process.env.ENVIO_SUBGRAPH_TRACES_URL = url();

    const empty = await fetchCalls(request({ addresses: { Staking: [] } }));
    expect([empty.items.length, requests.length, empty.latestFetchedBlockNumber]).toEqual([0, 0, 200]);

    const late = await fetchCalls(request({ registrations: [{ ...stakeHandler, startBlock: 150 }] }));
    expect(late.items.map((item) => item.blockNumber)).toEqual([190]);
  });

  it("asks again after a rate limit", async () => {
    let calls = 0;
    handler = () => {
      calls += 1;
      return calls === 1
        ? { status: 429, body: { error: "slow down" } }
        : { body: { archive_height: 1, next_block: 201, data: [] } };
    };
    process.env.ENVIO_SUBGRAPH_TRACES_URL = url();
    process.env.ENVIO_SUBGRAPH_RETRY_BACKOFF_MS = "5";
    const response = await fetchCalls(request());
    expect([calls, response.items.length]).toEqual([2, 0]);
  });
});

const parity = (over: Record<string, unknown>, action: Record<string, unknown> = {}) => ({
  type: "call",
  blockNumber: 110,
  transactionPosition: 1,
  traceAddress: [],
  action: { callType: "call", from: user, to: staking, input: stakeInput, value: "0x0", ...action },
  result: { output, gasUsed: "0x1" },
  ...over,
});

const rpcTx = (number: number, index: number) => ({
  hash: "0x" + number.toString(16).padStart(32, "0") + index.toString(16).padStart(32, "0"),
  transactionIndex: "0x" + index.toString(16),
  from: user,
  to: staking,
  value: "0x0",
  gas: "0x5208",
  gasPrice: "0x1",
  input: stakeInput,
  nonce: "0x7",
});

/** As the block comes without its transactions' bodies: hashes only. */
const rpcBlock = (number: number, transactions: number) => ({
  hash: "0x" + number.toString(16).padStart(64, "0"),
  parentHash: "0x" + "00".repeat(32),
  miner: "0x" + "bb".repeat(20),
  gasUsed: "0x10",
  gasLimit: "0x20",
  timestamp: "0x" + (1_000 + number).toString(16),
  transactions: Array.from({ length: transactions }, (_, index) => rpcTx(number, index).hash),
});

const rpcTransactionByHash = (hash: string) =>
  rpcTx(parseInt(hash.slice(2, 34), 16), parseInt(hash.slice(34), 16));

describe("an RPC node", () => {
  it("reads calls with trace_filter and the status of their transactions from the block's receipts", async () => {
    process.env.ENVIO_SUBGRAPH_TRACE_MODE = "trace_filter";
    handler = (body) => {
      switch (body.method) {
        case "trace_filter":
          return {
            body: {
              id: body.id,
              result: [
                parity({}),
                parity({ transactionPosition: 0, traceAddress: [0] }),
                // Not a call: a contract creation.
                { ...parity({}), type: "create" },
                // A reward has no transaction.
                parity({ transactionPosition: null }),
                parity({ transactionPosition: 0, traceAddress: [3], error: "Reverted" }),
              ],
            },
          };
        case "eth_getBlockByNumber":
          return { body: { id: body.id, result: rpcBlock(110, 2) } };
        case "eth_getTransactionByHash":
          return { body: { id: body.id, result: rpcTransactionByHash(body.params[0]) } };
        case "eth_getBlockReceipts":
          return {
            body: {
              id: body.id,
              result: [
                { transactionIndex: "0x0", status: "0x0" },
                { transactionIndex: "0x1", status: "0x1" },
              ],
            },
          };
      }
      return { body: { id: body.id, error: { code: -32601, message: "no" } } };
    };
    const response = await fetchCalls(request({ rpcUrls: [url()] }));

    expect(response.items.map((item) => [item.blockNumber, item.transactionIndex, item.traceAddress])).toEqual([
      [110, 1, []],
    ]);
    const filter = requests.find((r) => r.body.method === "trace_filter")!.body.params[0];
    expect(filter).toEqual({ fromBlock: "0x64", toBlock: "0xc8", toAddress: [staking] });
    expect(response.latestFetchedBlockNumber).toBe(200);
  });

  it("probes trace_filter over a few blocks, and without it reads debug_traceBlockByNumber one block at a time", async () => {
    process.env.ENVIO_SUBGRAPH_TRACE_BLOCKS_PER_PAGE = "3";
    handler = (body) => {
      switch (body.method) {
        case "trace_filter":
          return { status: 500, body: { error: "unsupported" } };
        case "debug_traceBlockByNumber": {
          const number = parseInt(body.params[0], 16);
          if (number !== 101) return { body: { id: body.id, result: [] } };
          return {
            body: {
              id: body.id,
              result: [
                // Transaction 0 reverted at the top.
                {
                  result: {
                    type: "CALL",
                    from: user,
                    to: staking,
                    input: stakeInput,
                    output: "0x",
                    error: "execution reverted",
                  },
                },
                {
                  result: {
                    type: "CALL",
                    from: user,
                    to: "0x9999999999999999999999999999999999999999",
                    input: "0x",
                    output: "0x",
                    calls: [
                      { type: "CALL", from: other, to: staking, input: stakeInput, output },
                      { type: "STATICCALL", from: other, to: staking, input: "0x70a08231" + "00".repeat(32), output },
                      { type: "DELEGATECALL", from: other, to: other, input: stakeInput, output },
                      {
                        type: "CALL",
                        from: other,
                        to: other,
                        input: "0x",
                        output: "0x",
                        calls: [{ type: "CALL", from: other, to: staking, input: stakeInput, output }],
                      },
                    ],
                  },
                },
              ],
            },
          };
        }
        case "eth_getBlockByNumber":
          return { body: { id: body.id, result: rpcBlock(101, 2) } };
        case "eth_getTransactionByHash":
          return { body: { id: body.id, result: rpcTransactionByHash(body.params[0]) } };
        case "eth_getBlockReceipts":
          return {
            body: {
              id: body.id,
              result: [
                { transactionIndex: "0x0", status: "0x0" },
                { transactionIndex: "0x1", status: "0x1" },
              ],
            },
          };
      }
      return { body: { id: body.id, error: { code: -32601, message: "no" } } };
    };

    const response = await fetchCalls(request({ rpcUrls: [url()], registrations: [stakeHandler, blockHandler] }));
    delete process.env.ENVIO_SUBGRAPH_TRACE_BLOCKS_PER_PAGE;

    expect(
      response.items.map((item) => [item.registrationIndex, item.transactionIndex, item.traceAddress]),
    ).toEqual([
      // Transaction 0's only call failed. Of transaction 1's, the delegatecall
      // and the call to another contract are not to this one.
      [3, 1, [0]],
      [4, 1, [0]],
      // A staticcall is a call to the address, though not to the handler's function.
      [4, 1, [1]],
      [3, 1, [3, 0]],
      [4, 1, [3, 0]],
    ]);
    // Three blocks per page.
    expect(response.latestFetchedBlockNumber).toBe(102);
  });
});

describe("trace formats", () => {
  it("reads a parity trace and a callTracer tree", () => {
    expect(callOfParityTrace(parity({ traceAddress: [1, 2] }, { callType: "delegatecall" }))).toMatchObject({
      blockNumber: 110,
      transactionIndex: 1,
      traceAddress: [1, 2],
      callType: "delegatecall",
      to: staking,
      error: false,
    });
    const { calls, topLevelFailed } = callsOfCallTracer(7, [
      { result: { type: "CALL", from: user, to: staking, input: "0xabcdef01", output: "0x", error: "out of gas" } },
    ]);
    expect([calls.length, [...topLevelFailed], calls[0].error]).toEqual([1, [0], true]);
  });
});
