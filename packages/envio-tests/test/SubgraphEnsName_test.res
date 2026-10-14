// `ens.nameByHash` through ENSRainbow. A hash its table doesn't hold reads as
// null, as on graph-node; a lookup service that is failing is asked again, not
// cached as a null for good. One that stays down — api.ensrainbow.io is gone,
// and the ENS subgraph died on its first lookup — answers like graph-node
// without a rainbow table: null, said once.
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
    if (url === "http://rainbow.test/v1/heal/" + vitalik) {
      return Promise.resolve(Response.json({ status: "success", label: "vitalik" }));
    }
    if (url.startsWith("https://tls.test/")) {
      tlsLookups++;
      return Promise.reject(
        new TypeError("fetch failed", {
          cause: Object.assign(new Error("Host: tls.test. is not in the cert's altnames"), {
            code: "ERR_TLS_CERT_ALTNAME_INVALID",
          }),
        }),
      );
    }
    if (url.startsWith("http://dead.test/")) {
      deadLookups++;
      // What Railway answers for an app it no longer runs.
      return Promise.resolve(
        Response.json({ status: "error", code: 404, message: "Application not found" }, { status: 404 }),
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

const vitalik = "0x" + "03".repeat(32);
let deadLookups = 0;
let tlsLookups = 0;

const named = (hash: string) => ({ contract: "Registry", event: "Named", params: { hash } });

describe("ens.nameByHash", () => {
  it("reads a hash the rainbow table doesn't hold as null", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [named(missing)] } } });
    t.expect(await indexer.Label.getAll()).toEqual([{ id: missing, name: "null" }]);
  });

  it("asks the ENSRainbow ENVIO_SUBGRAPH_ENS_RAINBOW_URL names", async (t) => {
    process.env.ENVIO_SUBGRAPH_ENS_RAINBOW_URL = "http://rainbow.test/v1/heal";
    try {
      const indexer = createTestIndexer();
      await indexer.process({ chains: { 1: { simulate: [named(vitalik)] } } });
      t.expect(await indexer.Label.getAll()).toEqual([{ id: vitalik, name: "vitalik" }]);
    } finally {
      delete process.env.ENVIO_SUBGRAPH_ENS_RAINBOW_URL;
    }
  });

  it("answers null without asking again once the service is gone", async (t) => {
    process.env.ENVIO_SUBGRAPH_ENS_RAINBOW_URL = "http://dead.test/v1/heal/";
    try {
      const indexer = createTestIndexer();
      await indexer.process({ chains: { 1: { simulate: [named(missing), named(flaky)] } } });
      t.expect({ labels: await indexer.Label.getAll(), deadLookups }).toEqual({
        labels: [
          { id: missing, name: "null" },
          { id: flaky, name: "null" },
        ],
        deadLookups: 1,
      });
    } finally {
      delete process.env.ENVIO_SUBGRAPH_ENS_RAINBOW_URL;
    }
  });

  it("takes a host serving someone else's certificate for down at once", async (t) => {
    process.env.ENVIO_SUBGRAPH_ENS_RAINBOW_URL = "https://tls.test/v1/heal/";
    try {
      const indexer = createTestIndexer();
      await indexer.process({ chains: { 1: { simulate: [named(missing)] } } });
      await indexer.process({ chains: { 1: { simulate: [named(flaky)] } } });
      t.expect({ labels: await indexer.Label.getAll(), tlsLookups }).toEqual({
        labels: [
          { id: missing, name: "null" },
          { id: flaky, name: "null" },
        ],
        tlsLookups: 1,
      });
    } finally {
      delete process.env.ENVIO_SUBGRAPH_ENS_RAINBOW_URL;
    }
  });

  it("asks a failing lookup again rather than answering null", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [named(flaky)] } } });
    t.expect(await indexer.Label.getAll()).toEqual([{ id: flaky, name: "vitalik" }]);
  });
});
`,
)
