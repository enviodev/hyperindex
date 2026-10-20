// zora-creator commits no subgraph.yaml: its `codegen` script runs `yarn
// gen-yaml-config`, which renders it with `yaml2json config/${NETWORK}.yaml |
// mustache - subgraph.template.yaml`. envio renders it for the network picked;
// the codegen script's own render step must not run after that and write the
// script's default network over it (here its tools fail outright, as they do
// when the repo's install never worked).
let template = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Pool
    network: {{network}}
    source:
      address: "{{pool}}"
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

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest="",
  ~schema="",
  ~fromProjectFiles=true,
  ~mappings=Dict.fromArray([
    ("subgraph.template.yaml", template),
    ("config/base.yaml", "network: base\npool: \"0x1111111111111111111111111111111111111111\"\n"),
    ("config/mainnet.yaml", "network: mainnet\npool: \"0x2222222222222222222222222222222222222222\"\n"),
    (".env", "ENVIO_SUBGRAPH_NETWORK=base\n"),
    (
      "schema.graphql",
      `
type Probe @entity {
  id: ID!
  value: String!
}
`,
    ),
    (
      "abis/Pool.json",
      `[{"type":"event","name":"Created","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
    (
      "package.json",
      `{"name":"zora-like","scripts":{
  "codegen": "npm run gen-yaml-config && graph codegen",
  "gen-yaml-config": "yaml2json config/\${NETWORK:-mainnet}.yaml | mustache - subgraph.template.yaml > subgraph.yaml"
}}`,
    ),
    // The repo's own tools, as its install leaves them: they render the
    // script's default network when NETWORK is unset.
    (
      "node_modules/.bin/yaml2json",
      "#!/bin/sh\ncat \"$1\"\n",
    ),
    (
      "node_modules/.bin/mustache",
      "#!/bin/sh\nsed -e 's/{{network}}/mainnet/' -e 's/{{pool}}/0x2222222222222222222222222222222222222222/' \"$2\"\n",
    ),
    (
      "node_modules/@graphprotocol/graph-cli/package.json",
      `{"name":"@graphprotocol/graph-cli","type":"module"}`,
    ),
    (
      "node_modules/@graphprotocol/graph-cli/dist/commands/codegen.js",
      `
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";

// Records which network's manifest graph codegen was given.
export default class CodegenCommand {
  static async run(argv) {
    const outputDir = argv[argv.indexOf("--output-dir") + 1];
    const network = readFileSync(argv.find((arg) => arg.endsWith(".yaml")), "utf8").match(/network: (\\S+)/)[1];
    mkdirSync(outputDir, { recursive: true });
    writeFileSync(path.join(outputDir, "manifest.ts"), "export const codegenNetwork = \\"" + network + "\\";\\n");
  }
}
`,
    ),
    (
      "src/pool.ts",
      `
import { Entity, store, dataSource } from "@graphprotocol/graph-ts";
import { codegenNetwork } from "../generated/manifest";

export function handleCreated(event: any): void {
  let probe = new Entity();
  probe.setString("value", dataSource.network() + " " + event.address.toHexString() + " " + codegenNetwork);
  store.set("Probe", "rendered", probe);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a manifest envio rendered from the repo's template", () => {
  it("indexes the network picked, and the codegen script leaves it", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 8453: { simulate: [{ contract: "Pool", event: "Created", params: { amount: 1n } }] } },
    });

    t.expect(await indexer.Probe.getAll()).toEqual([
      { id: "rendered", value: "base 0x1111111111111111111111111111111111111111 base" },
    ]);
  });
});
`,
)
