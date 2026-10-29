// A manifest with graft: used to be refused. Envio can't copy another
// deployment's data, so the graft is ignored (a full re-index from the data
// sources' startBlocks) and startup says so, loudly when a source starts after
// the graft block.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
graft:
  base: QmBaseDeployment
  block: 5
dataSources:
  - kind: ethereum/contract
    name: Factory
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Factory
      startBlock: 7
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Token
      abis:
        - name: Factory
          file: ./abis/Factory.json
      eventHandlers:
        - event: Listed(address)
          handler: handleListed
        - event: PairCreated(address,address)
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
        - Token
      abis:
        - name: Factory
          file: ./abis/Factory.json
      eventHandlers:
        - event: Listed(address)
          handler: handleListed
      file: ./src/factory.ts
`,
  ~schema=`
type Token @entity {
  id: ID!
  pairs: Int!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Factory.json",
      `[{"type":"event","name":"Listed","anonymous":false,"inputs":[{"name":"token","type":"address","indexed":false}]},{"type":"event","name":"PairCreated","anonymous":false,"inputs":[{"name":"token","type":"address","indexed":false},{"name":"pair","type":"address","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/factory.ts",
      `
import { DataSourceTemplate, Entity, log, store } from "@graphprotocol/graph-ts";

export function handleListed(event: any): void {
  let token = new Entity();
  token.setI32("pairs", 0);
  store.set("Token", event.params.token.toHexString(), token);
}

export function handlePairCreated(event: any): void {
  let id = event.params.token.toHexString();
  let token = store.get("Token", id);
  if (token == null) {
    log.error("Token not found: {}", [id]);
    return;
  }
  log.info("pair for {}", [id]);
  DataSourceTemplate.create("Pair", [event.params.pair.toHexString()]);
  token.setI32("pairs", token.getI32("pairs") + 1);
  store.set("Token", id, token);
}
`,
    ),
  ]),
  ~test=`
import { afterAll, beforeAll, describe, it } from "vitest";
import { createTestIndexer } from "envio";
import { onLog } from "envio/src/subgraph/log.ts";

const lines: string[] = [];
let stopLogging: () => void;

beforeAll(() => {
  stopLogging = onLog((level, message) => {
    lines.push(level + " " + message);
  });
});

afterAll(() => stopLogging());

const token = "0x2222222222222222222222222222222222222222";
const pair = "0x3333333333333333333333333333333333333333";

describe("an indexer starting on a subgraph", () => {
  it("warns that the graft is ignored and data may be missing", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { startBlock: 7, endBlock: 100, simulate: [{ contract: "Factory", event: "Listed", params: { token }, block: { number: 10 } }] } },
    });
    const warnings = lines.filter((line) => line.startsWith("warn ") && line.includes("grafts onto"));
    t.expect(warnings.length).toBe(1);
    t.expect(warnings[0]).toContain("QmBaseDeployment");
    t.expect(warnings[0]).toContain("IGNORED");
    t.expect(warnings[0]).toContain("DATA MAY BE MISSING");
    t.expect(warnings[0]).toContain("Factory (startBlock 7)");
  });
});
`,
)
