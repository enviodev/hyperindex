// The lookahead finds the handlers to preload again by the entity they read
// as absent. A Bytes id is stored as bytes, so the read and the save that
// creates it have to name it the same way, by its key, or the save never
// reaches the readers and their calls go out one event at a time.
let port = FreePort.pick()

let _ = InternalTestIndexer.fromSubgraph(
  ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", `http://127.0.0.1:${port}`)]),
  ~manifest=`
specVersion: 1.2.0
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Registry
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Registry
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Pool
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: Create(uint256)
          handler: handleCreate
        - event: Use(uint256)
          handler: handleUse
      file: ./src/registry.ts
`,
  ~schema=`
type Pool @entity {
  id: Bytes!
  total: BigInt!
  uses: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"Create","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]},{"type":"event","name":"Use","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { Address, BigInt, Bytes, Entity, ethereum, store } from "@graphprotocol/graph-ts";

class Registry extends ethereum.SmartContract {
  static bind(address: Address): Registry {
    return new Registry("Registry", address);
  }
  slot(index: BigInt): BigInt {
    let result = super.call("slot", "slot(uint256):(uint256)", [
      ethereum.Value.fromUnsignedBigInt(index),
    ]);
    return result[0].toBigInt();
  }
}

export function handleCreate(event: any): void {
  let pool = new Entity();
  pool.setBytes("id", Bytes.fromHexString("0x01"));
  pool.setBigInt("total", BigInt.fromI32(0));
  pool.setBigInt("uses", BigInt.fromI32(0));
  store.set("Pool", "0x01", pool);
}

export function handleUse(event: any): void {
  // What a v3 pool's Mint does: the pool was created earlier in the batch.
  let pool = store.get("Pool", "0x01")!;
  let uses = pool.getBigInt("uses").plus(BigInt.fromI32(1));
  let nonce: BigInt = event.params.nonce;
  let value = Registry.bind(event.address).slot(nonce);
  pool.setBigInt("total", pool.getBigInt("total").plus(value));
  pool.setBigInt("uses", uses);
  store.set("Pool", "0x01", pool);
}
`,
    ),
  ]),
  ~test=`
import { afterAll, beforeAll, describe, it } from "vitest";
import { createServer, type Server } from "node:http";
import { createTestIndexer } from "envio";

const USES = 16;

let server: Server;
// Calls being answered at once, whether they came alone or in a batch.
let inFlight = 0;
let peak = 0;

// slot(n) answers 2n.
const answer = (request: any) => ({
  jsonrpc: "2.0",
  id: request.id,
  result: "0x" + (2n * BigInt("0x" + request.params[0].data.slice(10))).toString(16).padStart(64, "0"),
});

beforeAll(async () => {
  server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const parsed = JSON.parse(body);
      const calls = Array.isArray(parsed) ? parsed.length : 1;
      inFlight += calls;
      peak = Math.max(peak, inFlight);
      setTimeout(() => {
        inFlight -= calls;
        res.end(JSON.stringify(Array.isArray(parsed) ? parsed.map(answer) : answer(parsed)));
      }, 40);
    });
  });
  await new Promise<void>((resolve) => server.listen(${port}, "127.0.0.1", resolve));
});

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("handlers waiting on a Bytes-id entity created earlier in the batch", () => {
  it("ask their contract calls together, not one event at a time", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Registry", event: "Create", params: { nonce: 0n } },
            ...Array.from({ length: USES }, (_, index) => ({
              contract: "Registry",
              event: "Use",
              params: { nonce: BigInt(index + 1) },
            })),
          ],
        },
      },
    });

    const pool = await indexer.Pool.get(Uint8Array.from([1]));
    // 2 * (1 + 2 + ... + 16) = 272
    t.expect({ total: pool?.total, uses: pool?.uses, concurrent: peak >= USES / 2 }).toEqual({
      total: 272n,
      uses: 16n,
      concurrent: true,
    });
  });
});
`,
)
