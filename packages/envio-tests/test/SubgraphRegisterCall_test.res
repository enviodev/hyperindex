// The dominant factory shape: read the pair's tokens over RPC, then create the
// template for it. The register pass runs at fetch time, so the call has to
// resolve there too — the address it decides is the one that gets indexed.
let _ = InternalTestIndexer.fromSubgraph(
  ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", "http://127.0.0.1:8601")]),
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
  symbol: String!
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
import { Address, DataSourceTemplate, Entity, ethereum, store } from "@graphprotocol/graph-ts";

class Factory extends ethereum.SmartContract {
  static bind(address: Address): Factory {
    return new Factory("Factory", address);
  }
  pairFor(): any {
    return this.call("pairFor", "pairFor():(address)", [])[0];
  }
  symbol(): any {
    return this.call("symbol", "symbol():(string)", [])[0];
  }
}

export function handlePairCreated(event: any): void {
  let factory = Factory.bind(event.address);
  // Both calls land before the create, which is the shape the register pass
  // used to refuse.
  let pair = factory.pairFor().toAddress();
  let symbol = factory.symbol().toString();

  DataSourceTemplate.create("Pair", [pair.toHexString()]);

  let entity = new Entity();
  entity.setString("symbol", symbol);
  store.set("Pair", pair.toHexString(), entity);
}
`,
    ),
    (
      "src/pair.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";

export function handleSync(event: any): void {
  // The register pass reads null for everything, so a template handler that
  // assumes its entity exists throws there. It creates nothing, so there is
  // nothing that pass could have collected.
  let existing = store.get("Pair", event.address.toHexString())!;
  let entity = new Entity();
  entity.setString("symbol", "synced-" + existing.symbol);
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

// pairFor() -> the pair address; symbol() -> "UNI-V2".
const PAIR_RESULT = "0x" + pair.slice(2).padStart(64, "0");
const SYMBOL_RESULT =
  "0x0000000000000000000000000000000000000000000000000000000000000020" +
  "0000000000000000000000000000000000000000000000000000000000000006" +
  "554e492d56320000000000000000000000000000000000000000000000000000";

const SYMBOL_SELECTOR = "0x95d89b41";

let server: Server;

beforeAll(async () => {
  server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const request = JSON.parse(body);
      const data: string = request.params?.[0]?.data ?? "";
      const reply = (result: unknown) =>
        res.end(JSON.stringify({ jsonrpc: "2.0", id: request.id, result }));
      if (request.method !== "eth_call") return reply("0x1");
      if (data.startsWith(SYMBOL_SELECTOR)) return reply(SYMBOL_RESULT);
      return reply(PAIR_RESULT);
    });
  });
  await new Promise<void>((resolve) => server.listen(8601, "127.0.0.1", resolve));
});

afterAll(async () => {
  await new Promise((resolve) => server.close(resolve));
});

describe("a contract call before dataSource.create()", () => {
  it("resolves in the register pass, so the template indexes the address it chose", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            {
              contract: "Factory",
              event: "PairCreated",
              params: { nonce: 1n },
              srcAddress: factory,
              block: { number: 10 },
            },
            {
              contract: "Pair",
              event: "Sync",
              params: { reserve: 5n },
              srcAddress: pair,
              block: { number: 20 },
            },
          ],
        },
      },
    });

    t.expect(await indexer.Pair.getAll()).toEqual([
      { id: pair.toLowerCase(), symbol: "synced-UNI-V2" },
    ]);
  });
});
`,
)
