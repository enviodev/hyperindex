// DAOhaus' moloch-v3 subgraph assembles subgraph.yaml per network from data
// source fragments (`manifests/baal-summoner-ds.yaml`, added for mainnet only)
// with a build script, and one mapping serves the summoner of every network: on
// sepolia it imports generated/BaalSummoner/BaalSummoner, which only the
// fragment declares. The developer's tree had it from a mainnet codegen; envio
// writes it from the fragment, with a warning.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: BaalSummonerV2
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: BaalSummonerV2
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Stake
      abis:
        - name: BaalSummonerV2
          file: ./abis/BaalSummoner2.0.0.json
      eventHandlers:
        - event: TokenStaked(uint256)
          handler: handleTokenStaked
      file: ./src/staker.ts
`

let schema = `
type Stake @entity {
  id: ID!
}
`

let abi = `[{"type":"event","name":"TokenStaked","anonymous":false,"inputs":[{"name":"tokenId","type":"uint256","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/BaalSummoner2.0.0.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/BaalSummoner2.0.0.json", abi),
    ("abis/BaalSummoner.json", abi),
    (
      "manifests/baal-summoner-ds.yaml",
      `kind: ethereum/contract
name: BaalSummoner
network:
source:
  address: ''
  abi: BaalSummoner
  startBlock:
mapping:
  kind: ethereum/events
  apiVersion: 0.0.5
  language: wasm/assemblyscript
  entities:
    - Stake
  abis:
    - name: BaalSummoner
      file: ./abis/BaalSummoner.json
  eventHandlers:
    - event: TokenStaked(uint256)
      handler: handleTokenStaked
  file: ./src/staker.ts
`,
    ),
    (
      "src/staker.ts",
      `
import { TokenStaked } from "../generated/BaalSummoner/BaalSummoner";
import { Stake } from "../generated/schema";

export function handleTokenStaked(event: TokenStaked): void {
  new Stake(event.params.tokenId.toString()).save();
}
`,
    ),
  ]),
  ~test=`
import { afterAll, beforeAll, describe, it } from "vitest";
import { createTestIndexer } from "envio";
import { onLog } from "envio/src/SubgraphLog.res.mjs";

const lines: string[] = [];
let stopLogging: () => void;

beforeAll(() => {
  stopLogging = onLog((level, message) => {
    lines.push(level + " " + message);
  });
});

afterAll(() => stopLogging());

describe("generated code for a data source only a manifest fragment declares", () => {
  it("is written from the fragment, with a warning", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { simulate: [{ contract: "BaalSummonerV2", event: "TokenStaked", params: { tokenId: 9n } }] } },
    });

    t.expect({
      stakes: await indexer.Stake.getAll(),
      warnings: lines.filter((line) => line.includes("generated/BaalSummoner/BaalSummoner.ts")),
    }).toEqual({
      stakes: [{ id: "9" }],
      warnings: [
        "warn Envio Subgraph wrote generated/BaalSummoner/BaalSummoner.ts from manifests/baal-summoner-ds.yaml: the " +
          "mappings import it, and \`graph codegen subgraph.yaml\` doesn't write it, so \`graph build\` of " +
          "subgraph.yaml fails on a clean checkout. The tree this subgraph was built with had it from an earlier " +
          "\`graph codegen manifests/baal-summoner-ds.yaml\`.",
      ],
    });
  });
});
`,
)
