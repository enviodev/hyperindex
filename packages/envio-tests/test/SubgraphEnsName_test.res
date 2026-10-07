// `ens.nameByHash` through ENSRainbow. A hash its table doesn't hold reads as
// null, as on graph-node; a lookup service that is failing is asked again, not
// cached as a null for good.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
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
        - Label
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: Named(string)
          handler: handleNamed
      file: ./src/registry.ts
`,
  ~schema=`
type Label @entity {
  id: ID!
  name: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"Named","anonymous":false,"inputs":[{"name":"hash","type":"string","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { Entity, ens, store } from "@graphprotocol/graph-ts";

export function handleNamed(event: any): void {
  let hash: string = event.params.hash;
  let name = ens.nameByHash(hash);
  let label = new Entity();
  label.setString("name", name === null ? "null" : name);
  store.set("Label", hash, label);
}
`,
    ),
  ]),
  ~test=`
import { beforeAll, describe, it } from "vitest";
import { createTestIndexer } from "envio";

const g = globalThis as any;
const missing = "0x" + "01".repeat(32);
const flaky = "0x" + "02".repeat(32);

beforeAll(() => {
  process.env.ENVIO_SUBGRAPH_RETRY_BACKOFF_MS = "20";
  let flakyFailures = 0;
  const realFetch = g.fetch;
  g.fetch = (input: any, init: any) => {
    const url = String(input);
    if (url.endsWith("/v1/heal/" + missing)) {
      return Promise.resolve(
        Response.json({ status: "error", error: "Label not found", errorCode: 404 }, { status: 404 }),
      );
    }
    if (url.endsWith("/v1/heal/" + flaky)) {
      return Promise.resolve(
        flakyFailures++ < 2
          ? Response.json({ status: "error", error: "Internal server error", errorCode: 500 }, { status: 500 })
          : Response.json({ status: "success", label: "vitalik" }),
      );
    }
    return realFetch(input, init);
  };
});

const named = (hash: string) => ({ contract: "Registry", event: "Named", params: { hash } });

describe("ens.nameByHash", () => {
  it("reads a hash the rainbow table doesn't hold as null", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [named(missing)] } } });
    t.expect(await indexer.Label.getAll()).toEqual([{ id: missing, name: "null" }]);
  });

  it("asks a failing lookup again rather than answering null", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [named(flaky)] } } });
    t.expect(await indexer.Label.getAll()).toEqual([{ id: flaky, name: "vitalik" }]);
  });
});
`,
)
