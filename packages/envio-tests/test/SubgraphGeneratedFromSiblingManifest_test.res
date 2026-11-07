// A project with one manifest per network often imports, from one network's
// mappings, generated code only another network's manifest declares: WOOFi's
// bsc mappings import generated/WooRouterV1_3/ (avax.yaml), DODO's bsc ones
// generated/DVMFactory/ (mainnet), flaunch's generated/BuyBackAndBurnFlay/
// (base-sepolia). graph codegen doesn't clean its output directory, so the
// developer's tree has those files from an earlier `graph codegen <other
// manifest>`, and the deployed subgraph was compiled against them; on a clean
// checkout `graph build` fails. envio writes the missing ones from the manifest
// that declares them, and says so.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Pool1
    network: base
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Pool
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Probe
      abis:
        - name: Pool
          file: ./abis/Pool.json
      eventHandlers:
        - event: Created(uint256)
          handler: handleCreated
      file: ./src/pool.ts
`

let schema = `
type Probe @entity {
  id: ID!
  value: String!
}
`

let abi = `[{"type":"event","name":"Created","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Pool.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    (
      "subgraph.base-sepolia.yaml",
      manifest
      ->String.replace("network: base", "network: base-sepolia")
      ->String.replace("name: Pool1\n", "name: Pool\n"),
    ),
    ("schema.graphql", schema),
    ("abis/Pool.json", abi),
    (
      "src/pool.ts",
      `
import { Created } from "../generated/Pool1/Pool";
import { Created as SepoliaCreated } from "../generated/Pool/Pool";
import { Probe } from "../generated/schema";

export function handleCreated(event: Created): void {
  let probe = new Probe("codegen");
  probe.value = event.params.amount.toString();
  probe.save();
}

export function handleSepoliaCreated(event: SepoliaCreated): void {}
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

describe("generated code only another manifest of the project declares", () => {
  it("is written from that manifest, with a warning", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 8453: { simulate: [{ contract: "Pool1", event: "Created", params: { amount: 4n } }] } },
    });

    t.expect({
      probes: await indexer.Probe.getAll(),
      warnings: lines.filter((line) => line.includes("subgraph.base-sepolia.yaml")),
    }).toEqual({
      probes: [{ id: "codegen", value: "4" }],
      warnings: [
        "warn Envio Subgraph wrote generated/Pool/Pool.ts from subgraph.base-sepolia.yaml: the mappings import it, " +
          "and \`graph codegen subgraph.yaml\` doesn't write it, so \`graph build\` of subgraph.yaml fails on a clean " +
          "checkout. The tree this subgraph was built with had it from an earlier \`graph codegen subgraph.base-sepolia.yaml\`.",
      ],
    });
  });
});
`,
)
