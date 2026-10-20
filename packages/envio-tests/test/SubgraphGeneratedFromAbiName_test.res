// A mapping importing generated/<X>/<ABI>.ts for a data source the project no
// longer declares: revert's uni-v3-staker imports generated/UniV3Staker/ after
// renaming its data sources UniV3Staker1.0.0/1.0.2; Mitosis' imports
// generated/ERC20/ERC20 from a data source since renamed. The tree it was built
// with still had the file, and what graph codegen writes there depends on the
// ABI alone (every data source using an ABI gets the same file), so envio writes
// it from the manifest's ABI of that name, with a warning.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: UniV3Staker1.0.0
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: UniV3Staker
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Stake
      abis:
        - name: UniV3Staker
          file: ./abis/UniV3Staker.json
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
  ~files=Dict.fromArray([("abis/UniV3Staker.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/UniV3Staker.json", abi),
    (
      "src/staker.ts",
      `
import { TokenStaked } from "../generated/UniV3Staker/UniV3Staker";
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
import { getLogger, setLogger } from "envio/src/Logging.res.mjs";

const lines: string[] = [];
let installed: unknown;

beforeAll(() => {
  installed = getLogger();
  const capture: any = { level: "info", child: () => capture, isLevelEnabled: () => true };
  for (const level of ["trace", "debug", "info", "warn", "error", "fatal", "udebug", "uinfo", "uwarn", "uerror"]) {
    capture[level] = (params: unknown, message?: string) => {
      lines.push(level + " " + (message ?? (typeof params === "string" ? params : JSON.stringify(params))));
    };
  }
  setLogger(capture);
});

afterAll(() => setLogger(installed));

describe("generated code for a data source the project no longer declares", () => {
  it("is written from the ABI of that name, with a warning", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { simulate: [{ contract: "UniV3Staker1_0_0", event: "TokenStaked", params: { tokenId: 9n } }] } },
    });

    t.expect({
      stakes: await indexer.Stake.getAll(),
      warnings: lines.filter((line) => line.includes("generated/UniV3Staker/UniV3Staker.ts")),
    }).toEqual({
      stakes: [{ id: "9" }],
      warnings: [
        "warn Envio Subgraph wrote generated/UniV3Staker/UniV3Staker.ts from the ABI \\"UniV3Staker\\" " +
          "(abis/UniV3Staker.json): the mappings import it, and no manifest of the project has a data source or " +
          "template named \\"UniV3Staker\\" that graph codegen would write it for, so \`graph build\` fails on a clean " +
          "checkout. The tree this subgraph was built with had it from an earlier manifest; graph codegen writes " +
          "the same file for every data source with that ABI.",
      ],
    });
  });
});
`,
)
