// A graph-cli that is installed but crashes (the CommonJS 0.50-0.91 releases'
// `Command.run is not a function`) falls back to envio's own generated/.

let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Pool
    network: mainnet
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
  amount: BigInt
}
`

let abi = `[{"type":"event","name":"Created","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Pool.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Pool.json", abi),
    ("generated/.gitkeep", ""),
    (
      "node_modules/@graphprotocol/graph-cli/package.json",
      `{"name":"@graphprotocol/graph-cli","type":"module"}`,
    ),
    (
      "node_modules/@graphprotocol/graph-cli/dist/commands/codegen.js",
      `
export default class CodegenCommand {
  static async run() {
    throw new Error("Command.run is not a function");
  }
}
`,
    ),
    (
      "src/pool.ts",
      `
import { Created } from "../generated/Pool/Pool";
import { Probe } from "../generated/schema";

export function handleCreated(event: Created): void {
  let probe = new Probe("bundled");
  probe.value = event.params.amount.toString();
  probe.amount = event.params.amount;
  probe.save();
  let again = Probe.load("bundled");
  if (again != null) {
    again.value = again.value + "!";
    again.save();
  }
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a failing graph-cli", () => {
  it("writes the generated code itself", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Pool", event: "Created", params: { amount: 7n } }] } },
    });

    t.expect(await indexer.Probe.getAll()).toEqual([{ id: "bundled", value: "7!", amount: 7n }]);
  });
});
`,
)
