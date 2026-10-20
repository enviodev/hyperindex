// A register pass replays its handler once per contract call it hasn't been
// answered yet, so a handler making N calls before its create() needs N
// rounds. graph-node has no such count: sweem's Aave handler reads ten values
// per reserve of a pool's reserve list and stopped the run at the cap of 100
// rounds, a limit the handler pass sets at 10000.
let _ = InternalTestIndexer.fromSubgraph(
  ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", "http://127.0.0.1:8611")]),
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Factory
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Factory
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Pair
      abis:
        - name: Factory
          file: ./abis/Factory.json
      eventHandlers:
        - event: PairCreated(uint256)
          handler: handlePairCreated
      file: ./src/factory.ts
templates:
  - kind: ethereum/contract
    name: Pair
    network: mainnet
    source:
      abi: Factory
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Pair
      abis:
        - name: Factory
          file: ./abis/Factory.json
      eventHandlers:
        - event: Sync(uint256)
          handler: handleSync
      file: ./src/pair.ts
`,
  ~schema=`
type Pair @entity {
  id: ID!
  calls: Int!
  synced: Boolean!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Factory.json",
      `[{"type":"event","name":"PairCreated","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]},{"type":"event","name":"Sync","anonymous":false,"inputs":[{"name":"reserve","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/factory.ts",
      `
import { Address, BigInt, DataSourceTemplate, Entity, ethereum, store } from "@graphprotocol/graph-ts";

class Factory extends ethereum.SmartContract {
  static bind(address: Address): Factory {
    return new Factory("Factory", address);
  }
  pairAt(index: i32): Address {
    return this.call("pairAt", "pairAt(uint256):(address)", [ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(index))])[0].toAddress();
  }
}

export function handlePairCreated(event: any): void {
  let factory = Factory.bind(event.address);
  let pair = Address.zero();
  for (let i = 0; i < 150; i++) {
    pair = factory.pairAt(i);
  }
  DataSourceTemplate.create("Pair", [pair.toHexString()]);
  let entity = new Entity();
  entity.setI32("calls", 150);
  entity.setBoolean("synced", false);
  store.set("Pair", pair.toHexString(), entity);
}
`,
    ),
    (
      "src/pair.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";

export function handleSync(event: any): void {
  let entity = new Entity();
  entity.setBoolean("synced", true);
  store.set("Pair", event.address.toHexString(), entity);
}
`,
    ),
  ]),
  ~test=`
import { afterAll, beforeAll, describe, it } from "vitest";
import { createServer, type Server } from "node:http";
import { createTestIndexer } from "envio";

const factory = "0x1111111111111111111111111111111111111111" as const;
const pair = "0x2222222222222222222222222222222222222222" as const;
const PAIR_RESULT = "0x" + pair.slice(2).padStart(64, "0");

let server: Server;

beforeAll(async () => {
  server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const parsed = JSON.parse(body);
      const answer = (request: any) => ({ jsonrpc: "2.0", id: request.id, result: request.method === "eth_call" ? PAIR_RESULT : "0x1" });
      res.end(JSON.stringify(Array.isArray(parsed) ? parsed.map(answer) : answer(parsed)));
    });
  });
  await new Promise<void>((resolve) => server.listen(8611, "127.0.0.1", resolve));
});

afterAll(async () => {
  await new Promise((resolve) => server.close(resolve));
});

describe("a register pass that makes many calls before its create()", () => {
  it("replays until every call is answered, so the template is indexed", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            { contract: "Factory", event: "PairCreated", params: { nonce: 1n }, srcAddress: factory, block: { number: 10 } },
            { contract: "Pair", event: "Sync", params: { reserve: 5n }, srcAddress: pair, block: { number: 20 } },
          ],
        },
      },
    });
    t.expect(await indexer.Pair.getAll()).toEqual([{ id: pair, calls: 150, synced: true }]);
  });
});
`,
)
