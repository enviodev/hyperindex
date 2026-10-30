// A graph-ts BigInt is its bytes, and graph-node builds every one it hands a
// mapping from chain data with `BigInt::from(u64)` or
// `BigInt::from_unsigned_u256` and writes it as `to_signed_bytes_le`
// (chain/ethereum/src/runtime/abi.rs, runtime/wasm/src/to_from/external.rs):
// the minimal two's complement, 189 as `bd00`, 258 as `0201`. A mapping sees
// the width through `Bytes.fromBigInt`, `byteLength` or `changetype<Bytes>`,
// and ids built that way differ when it is off (79a64fd69 fixed
// `event.logIndex`). This reads every chain BigInt an event, its receipt and
// receipt logs, a block handler's block and a call hand over, and checks each
// one's bytes against that encoding.
let port = FreePort.pick()

let _ = InternalTestIndexer.fromSubgraph(
  ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", `http://127.0.0.1:${port}`)]),
  ~manifest=`
specVersion: 0.0.8
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Pool
    network: evm-1404
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Pool
      startBlock: 258
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Width
      abis:
        - name: Pool
          file: ./abis/Pool.json
      eventHandlers:
        - event: Supply(uint256)
          handler: handleSupply
          receipt: true
      callHandlers:
        - function: deposit(uint256)
          handler: handleDeposit
      blockHandlers:
        - handler: handleBlock
      file: ./src/pool.ts
`,
  ~schema=`
type Width @entity {
  id: ID!
  bytes: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Pool.json",
      `[
        {"type":"event","name":"Supply","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]},
        {"type":"function","name":"deposit","stateMutability":"nonpayable","inputs":[{"name":"amount","type":"uint256"}],"outputs":[{"name":"shares","type":"uint256"}]}
      ]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/pool.ts",
      `
import { BigInt, Bytes, Entity, ethereum, store } from "@graphprotocol/graph-ts";

function width(id: string, value: BigInt): void {
  let row = new Entity();
  row.setString("bytes", Bytes.fromBigInt(value).toHexString());
  store.set("Width", id, row);
}

function blockWidths(prefix: string, block: ethereum.Block): void {
  width(prefix + "number", block.number);
  width(prefix + "timestamp", block.timestamp);
  width(prefix + "gasUsed", block.gasUsed);
  width(prefix + "gasLimit", block.gasLimit);
  width(prefix + "difficulty", block.difficulty);
  width(prefix + "totalDifficulty", block.totalDifficulty);
  width(prefix + "size", block.size!);
  width(prefix + "baseFeePerGas", block.baseFeePerGas!);
}

function transactionWidths(prefix: string, transaction: ethereum.Transaction): void {
  width(prefix + "index", transaction.index);
  width(prefix + "value", transaction.value);
  width(prefix + "gasLimit", transaction.gasLimit);
  width(prefix + "gasPrice", transaction.gasPrice);
  width(prefix + "nonce", transaction.nonce);
}

export function handleSupply(event: ethereum.Event): void {
  width("event.logIndex", event.logIndex);
  width("event.transactionLogIndex", event.transactionLogIndex);
  width("event.amount", event.parameters[0].value.toBigInt());
  blockWidths("event.block.", event.block);
  transactionWidths("event.transaction.", event.transaction);
  let receipt = event.receipt!;
  width("receipt.transactionIndex", receipt.transactionIndex);
  width("receipt.blockNumber", receipt.blockNumber);
  width("receipt.cumulativeGasUsed", receipt.cumulativeGasUsed);
  width("receipt.gasUsed", receipt.gasUsed);
  width("receipt.status", receipt.status);
  for (let i = 0; i < receipt.logs.length; i++) {
    let log = receipt.logs[i];
    let prefix = "receipt.logs[" + i.toString() + "].";
    width(prefix + "transactionIndex", log.transactionIndex);
    width(prefix + "logIndex", log.logIndex);
    width(prefix + "transactionLogIndex", log.transactionLogIndex);
    let row = new Entity();
    row.setString("bytes", log.blockNumber.toHexString());
    store.set("Width", prefix + "blockNumber", row);
  }
}

export function handleBlock(block: ethereum.Block): void {
  blockWidths("blockHandler[" + block.number.toString() + "].", block);
}

export function handleDeposit(call: ethereum.Call): void {
  width("call.amount", call.inputValues[0].value.toBigInt());
  width("call.shares", call.outputValues[0].value.toBigInt());
  blockWidths("call.block.", call.block);
  transactionWidths("call.transaction.", call.transaction);
}
`,
    ),
  ]),
  ~test=`
import { afterAll, beforeAll, describe, it } from "vitest";
import { createServer, type Server } from "node:http";
import { encodeAbiParameters, encodeFunctionData, parseAbi, toFunctionSelector } from "viem";
import { createTestIndexer } from "envio";

const g = globalThis as any;
const hex = (n: bigint | number) => "0x" + n.toString(16);
const ZERO32 = "0x" + "00".repeat(32);
const pool = "0x1111111111111111111111111111111111111111";
const txHash = "0x" + "ab".repeat(32);
const blockHash = "0x" + "cd".repeat(32);

// num_bigint's to_signed_bytes_le, which graph-node writes a BigInt as.
const signedLe = (value: bigint) => {
  const bytes: number[] = [];
  let rest = value;
  for (;;) {
    const byte = Number(BigInt.asUintN(8, rest));
    bytes.push(byte);
    rest >>= 8n;
    if ((rest === 0n && (byte & 0x80) === 0) || (rest === -1n && (byte & 0x80) !== 0)) break;
  }
  return "0x" + bytes.map((byte) => byte.toString(16).padStart(2, "0")).join("");
};

// Each value is one whose minimal bytes differ from a fixed i32's or u64's.
const block = {
  number: 258,
  timestamp: 1_700_000_000,
  gasUsed: 128n,
  gasLimit: 30_000_000n,
  difficulty: 0n,
  totalDifficulty: 1n << 63n,
  size: 544n,
  baseFeePerGas: 7n,
};
const transaction = {
  transactionIndex: 300,
  hash: txHash,
  value: 255n,
  gas: 21_000n,
  gasPrice: 1n << 31n,
  nonce: 128n,
  cumulativeGasUsed: 65_535n,
  gasUsed: 21_000n,
  status: 1,
};
const receiptLogs = [5, 189].map((logIndex) => ({
  address: pool,
  topics: [ZERO32],
  data: "0x",
  blockNumber: hex(block.number),
  blockHash,
  transactionHash: txHash,
  transactionIndex: hex(transaction.transactionIndex),
  logIndex: hex(logIndex),
  removed: false,
}));

let server: Server;

beforeAll(async () => {
  server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const request = JSON.parse(body);
      const reply = (result: unknown) => res.end(JSON.stringify({ jsonrpc: "2.0", id: request.id, result }));
      switch (request.method) {
        case "eth_getBlockByNumber":
          return reply({
            number: request.params[0],
            hash: blockHash,
            parentHash: ZERO32,
            timestamp: hex(block.timestamp),
            nonce: "0x0000000000000000",
            difficulty: hex(block.difficulty),
            totalDifficulty: hex(block.totalDifficulty),
            gasLimit: hex(block.gasLimit),
            gasUsed: hex(block.gasUsed),
            baseFeePerGas: hex(block.baseFeePerGas),
            miner: "0x0000000000000000000000000000000000000000",
            extraData: "0x",
            logsBloom: "0x" + "00".repeat(256),
            sha3Uncles: ZERO32,
            stateRoot: ZERO32,
            transactionsRoot: ZERO32,
            receiptsRoot: ZERO32,
            size: hex(block.size),
            transactions: [],
            uncles: [],
          });
        case "eth_getTransactionReceipt":
          return reply({
            transactionHash: txHash,
            transactionIndex: hex(transaction.transactionIndex),
            blockHash,
            blockNumber: hex(block.number),
            from: "0x0000000000000000000000000000000000000002",
            to: pool,
            cumulativeGasUsed: hex(transaction.cumulativeGasUsed),
            gasUsed: hex(transaction.gasUsed),
            effectiveGasPrice: hex(transaction.gasPrice),
            contractAddress: null,
            logs: receiptLogs,
            logsBloom: "0x" + "00".repeat(256),
            status: "0x1",
            type: "0x0",
          });
        default:
          return reply(hex(1404));
      }
    });
  });
  await new Promise<void>((resolve) => server.listen(${port}, "127.0.0.1", resolve));

  // HyperSync doesn't serve chain 1404: nothing may reach it.
  const realFetch = g.fetch;
  g.fetch = (input: any, init: any) =>
    String(input).includes("hypersync.xyz") ? Promise.reject(new TypeError("fetch failed")) : realFetch(input, init);
});

afterAll(() => server.close());

describe("BigInts from chain data", () => {
  it("have graph-node's minimal two's complement bytes", async (t) => {
    const indexer = createTestIndexer();
    const abi = parseAbi(["function deposit(uint256 amount) returns (uint256 shares)"]);
    const depositName = "__envio_call_" + toFunctionSelector("deposit(uint256)").slice(2) + "_deposit";

    await indexer.process({
      chains: {
        1404: {
          startBlock: 258,
          endBlock: 259,
          simulate: [
            {
              contract: "Pool",
              event: "Supply",
              srcAddress: pool,
              params: { amount: 189n },
              block,
              transaction,
              logIndex: 189,
            },
            {
              contract: "Pool",
              event: depositName,
              srcAddress: pool,
              params: {
                callInput: encodeFunctionData({ abi, functionName: "deposit", args: [189n] }),
                callOutput: encodeAbiParameters([{ type: "uint256" }], [258n]),
                callFrom: "0x0000000000000000000000000000000000000002",
                callValue: 0n,
                callGasUsed: 21_000n,
              },
              block,
              transaction,
              logIndex: 0,
            },
            // The block handler's block 259, which no event carries.
            { block: { ...block, number: 259 } },
          ],
        },
      },
    });

    const blockWidths = (prefix: string, number = block.number) => ({
      [prefix + "number"]: signedLe(BigInt(number)),
      [prefix + "timestamp"]: signedLe(BigInt(block.timestamp)),
      [prefix + "gasUsed"]: signedLe(block.gasUsed),
      [prefix + "gasLimit"]: signedLe(block.gasLimit),
      [prefix + "difficulty"]: signedLe(block.difficulty),
      [prefix + "totalDifficulty"]: signedLe(block.totalDifficulty),
      [prefix + "size"]: signedLe(block.size),
      [prefix + "baseFeePerGas"]: signedLe(block.baseFeePerGas),
    });
    const transactionWidths = (prefix: string) => ({
      [prefix + "index"]: signedLe(BigInt(transaction.transactionIndex)),
      [prefix + "value"]: signedLe(transaction.value),
      [prefix + "gasLimit"]: signedLe(transaction.gas),
      [prefix + "gasPrice"]: signedLe(transaction.gasPrice),
      [prefix + "nonce"]: signedLe(transaction.nonce),
    });
    const logWidths = (i: number, logIndex: number) => ({
      [\`receipt.logs[\${i}].transactionIndex\`]: signedLe(BigInt(transaction.transactionIndex)),
      [\`receipt.logs[\${i}].logIndex\`]: signedLe(BigInt(logIndex)),
      // Where no client sets it, the log's index stands in.
      [\`receipt.logs[\${i}].transactionLogIndex\`]: signedLe(BigInt(logIndex)),
      // graph-ts types it Bytes; graph-node writes the number's BigInt bytes.
      [\`receipt.logs[\${i}].blockNumber\`]: signedLe(BigInt(block.number)),
    });

    const rows = await indexer.Width.getAll();
    t.expect(Object.fromEntries(rows.map((row: any) => [row.id, row.bytes]))).toEqual({
      "event.logIndex": signedLe(189n),
      "event.transactionLogIndex": signedLe(189n),
      "event.amount": signedLe(189n),
      ...blockWidths("event.block."),
      ...transactionWidths("event.transaction."),
      "receipt.transactionIndex": signedLe(BigInt(transaction.transactionIndex)),
      "receipt.blockNumber": signedLe(BigInt(block.number)),
      "receipt.cumulativeGasUsed": signedLe(transaction.cumulativeGasUsed),
      "receipt.gasUsed": signedLe(transaction.gasUsed),
      "receipt.status": signedLe(1n),
      ...logWidths(0, 5),
      ...logWidths(1, 189),
      ...blockWidths("blockHandler[258].", 258),
      ...blockWidths("blockHandler[259].", 259),
      "call.amount": signedLe(189n),
      "call.shares": signedLe(258n),
      ...blockWidths("call.block."),
      ...transactionWidths("call.transaction."),
    });
  });
});
`,
)
