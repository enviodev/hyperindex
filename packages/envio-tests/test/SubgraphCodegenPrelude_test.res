// cope-market's erc4626-vault commits no subgraph.yaml: `"codegen": "node
// scripts/build-manifest.mjs ${NETWORK:-arc-testnet} && graph codegen"`
// writes it in its first step. envio runs that step first, with the network
// picked; its codegen must not run it again, without the network, and write
// the script's default over it.
let template = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Vault
    network: NETWORK
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Vault
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Probe
      abis:
        - name: Vault
          file: ./abis/Vault.json
      eventHandlers:
        - event: Deposited(uint256)
          handler: handleDeposited
      file: ./src/vault.ts
`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest="",
  ~schema="",
  ~fromProjectFiles=true,
  ~mappings=Dict.fromArray([
    ("subgraph.template.yaml", template),
    (
      "scripts/build-manifest.sh",
      "sed \"s/network: NETWORK/network: $1/\" subgraph.template.yaml > subgraph.yaml\n",
    ),
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
      "abis/Vault.json",
      `[{"type":"event","name":"Deposited","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
    (
      "package.json",
      `{"name":"cope-like","scripts":{"codegen": "sh scripts/build-manifest.sh \${NETWORK:-mainnet} && graph codegen"}}`,
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
      "src/vault.ts",
      `
import { Entity, store, dataSource } from "@graphprotocol/graph-ts";
import { codegenNetwork } from "../generated/manifest";

export function handleDeposited(event: any): void {
  let probe = new Entity();
  probe.setString("value", dataSource.network() + " " + codegenNetwork);
  store.set("Probe", "vault", probe);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a manifest the codegen script's first step writes", () => {
  it("is written for the network picked, once", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 8453: { simulate: [{ contract: "Vault", event: "Deposited", params: { amount: 1n } }] } },
    });

    t.expect(await indexer.Probe.getAll()).toEqual([{ id: "vault", value: "base base" }]);
  });
});
`,
)
