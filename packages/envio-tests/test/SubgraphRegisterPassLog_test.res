// The register pass reruns a mapping against a store that reads null, only to
// collect `dataSource.create()` calls, so whatever the mapping logs there is
// about a world that doesn't exist. Notional printed 190+ `Token not found`
// errors from it that graph-node never would.
let _ = InternalTestIndexer.fromSubgraph(
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
import { getLogger, setLogger } from "envio/src/Logging.res.mjs";

const lines: string[] = [];
let installed: unknown;

beforeAll(() => {
  installed = getLogger();
  const capture: any = {
    level: "info",
    child: () => capture,
    isLevelEnabled: () => true,
  };
  for (const level of ["trace", "debug", "info", "warn", "error", "fatal", "udebug", "uinfo", "uwarn", "uerror"]) {
    capture[level] = (params: unknown, message?: string) => {
      if (level.startsWith("u")) lines.push(level + " " + (message ?? String(params)));
    };
  }
  setLogger(capture);
});

afterAll(() => setLogger(installed));

const token = "0x2222222222222222222222222222222222222222";
const pair = "0x3333333333333333333333333333333333333333";

describe("the register pass", () => {
  it("logs nothing a mapping says about the null store it runs against", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            { contract: "Factory", event: "Listed", params: { token }, block: { number: 10 } },
            { contract: "Factory", event: "PairCreated", params: { token, pair }, block: { number: 20 } },
          ],
        },
      },
    });

    t.expect({ tokens: await indexer.Token.getAll(), lines }).toEqual({
      tokens: [{ id: token, pairs: 1 }],
      lines: ["uinfo pair for " + token],
    });
  });
});
`,
)
