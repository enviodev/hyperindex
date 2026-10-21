import { describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

// UMA writes its manifest with `"prepare:polygon": "scripts/build-manifest.sh
// polygon && yarn codegen && yarn build"`, and build-manifest.sh echoes what it
// renders before writing it; envio runs that one script for the network picked.
// `envio start` parses the config inside Node, which holds its stdin, stdout
// and stderr close-on-exec: a child that only inherited them started with all
// three closed, so the script's `echo` failed and the `&&` after it never wrote
// the manifest. The parse runs here in a Node process of its own, as the CLI
// runs it, with its output captured.
const template = `specVersion: 0.0.5
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
`;

describe("the one package.json script that writes the manifest", () => {
  it("runs with envio's stdout and stderr", () => {
    const project = mkdtempSync(path.join(tmpdir(), "envio-writer-script-output-"));
    const files: Record<string, string> = {
      "subgraph.template.yaml": template,
      "scripts/build-manifest.sh":
        'echo "Generating the manifest for $1" && echo "to stderr" >&2 && sed "s/network: NETWORK/network: $1/" subgraph.template.yaml > subgraph.yaml\n',
      ".env": "ENVIO_SUBGRAPH_NETWORK=base\n",
      "schema.graphql": "type Probe @entity {\n  id: ID!\n  value: String!\n}\n",
      "abis/Vault.json":
        '[{"type":"event","name":"Deposited","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]',
      "src/vault.ts": "export function handleDeposited(event: any): void {}\n",
      "package.json": JSON.stringify({
        name: "uma-like",
        scripts: {
          "prepare:base": "sh scripts/build-manifest.sh base && yarn codegen",
          "prepare:mainnet": "sh scripts/build-manifest.sh mainnet && yarn codegen",
          codegen: "graph codegen",
        },
      }),
    };
    for (const [file, text] of Object.entries(files)) {
      mkdirSync(path.dirname(path.join(project, file)), { recursive: true });
      writeFileSync(path.join(project, file), text);
    }

    const parse = `
      import { createRequire } from "node:module";
      const addon = createRequire(import.meta.url)(process.env.ENVIO_DEV_ADDON);
      const config = JSON.parse(addon.getConfigJson(null, process.argv[1]));
      console.log("chains: " + Object.values(config.evm.chains).map((chain) => chain.id).join(","));
    `;
    const output = execFileSync(process.execPath, ["--input-type=module", "-e", parse, project], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });

    expect({
      output: output.split("\n").filter((line) => line.startsWith("Generating") || line.startsWith("chains")),
      manifest: readFileSync(path.join(project, "subgraph.yaml"), "utf8").includes("network: base"),
    }).toEqual({ output: ["Generating the manifest for base", "chains: 8453"], manifest: true });
  });
});
