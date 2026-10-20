// A handler that reads an entity an earlier event of the same batch creates
// finds nothing in preload, so preload makes none of its contract calls and the
// execute pass asks them one event at a time: a round trip per call, in series.
// Once the entity exists, those handlers are preloaded again, so their calls go
// out together while execute works through the events before them.
let _ = InternalTestIndexer.fromSubgraph(
  ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", "http://127.0.0.1:4823")]),
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
  id: ID!
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
import { Address, BigInt, Entity, ethereum, store } from "@graphprotocol/graph-ts";

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
  pool.setString("id", "pool");
  pool.setBigInt("total", BigInt.fromI32(0));
  pool.setBigInt("uses", BigInt.fromI32(0));
  store.set("Pool", "pool", pool);
}

export function handleUse(event: any): void {
  // What a v3 pool's Mint does: the pool was created earlier in the batch.
  let pool = store.get("Pool", "pool")!;
  let uses = pool.getBigInt("uses").plus(BigInt.fromI32(1));
  let nonce: BigInt = event.params.nonce;
  let value = Registry.bind(event.address).slot(nonce);
  pool.setBigInt("total", pool.getBigInt("total").plus(value));
  pool.setBigInt("uses", uses);
  store.set("Pool", "pool", pool);
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
let inFlight = 0;
let peak = 0;

beforeAll(async () => {
  server = createServer((req, res) => {
    inFlight++;
    peak = Math.max(peak, inFlight);
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const request = JSON.parse(body);
      // slot(n) answers 2n.
      const n = BigInt("0x" + request.params[0].data.slice(10));
      setTimeout(() => {
        inFlight--;
        res.end(
          JSON.stringify({
            jsonrpc: "2.0",
            id: request.id,
            result: "0x" + (2n * n).toString(16).padStart(64, "0"),
          }),
        );
      }, 40);
    });
  });
  await new Promise<void>((resolve) => server.listen(4823, "127.0.0.1", resolve));
});

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("handlers waiting on an entity created earlier in the batch", () => {
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

    const pool = await indexer.Pool.get("pool");
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
