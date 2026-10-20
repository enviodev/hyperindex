import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { mkdirSync, mkdtempSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

// `envio start` in a project directory hands the runtime its root as ".", and
// a mapping that imports no `schema` (Kleros' import hand-split
// `generated/PolicyRegistrySchema` files) leaves the generated directory at its
// "generated" default: both relative, while every import the scan resolves is
// absolute. No missing file was ever under the directory, so a tree the CLI had
// written without them counted as complete and nothing filled it. The rung-1
// helper always passes an absolute root, so this calls the runtime's own entry
// with the relative one the CLI passes.
type GraphCli = typeof import("envio/src/subgraph/graph-cli.ts");
let graphCli: GraphCli;
const cwd = process.cwd();
const project = mkdtempSync(path.join(tmpdir(), "envio-generated-relative-"));

beforeAll(async () => {
  const { registerTsHooks } = await import("envio/src/HandlerLoader.res.mjs");
  registerTsHooks();
  graphCli = await import("envio/src/subgraph/graph-cli.ts");
  const write = (file: string, text: string) => {
    mkdirSync(path.dirname(path.join(project, file)), { recursive: true });
    writeFileSync(path.join(project, file), text);
  };
  write(
    "subgraph.yaml",
    `specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Pool
    network: mainnet
    source:
      abi: Pool
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities: [Probe]
      abis:
        - name: Pool
          file: ./abis/Pool.json
      eventHandlers:
        - event: Created(uint256)
          handler: handleCreated
      file: ./src/pool.ts
`,
  );
  write("schema.graphql", "type Probe @entity { id: ID! }\n");
  write(
    "abis/Pool.json",
    `[{"type":"event","name":"Created","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
  );
  write("src/pool.ts", `import { Created } from "../generated/Pool/Pool";\nexport function handleCreated(event: Created): void {}\n`);
  // What the CLI leaves when it wrote a tree the mappings import more than.
  write("generated/schema.ts", "export {};\n");
  process.chdir(project);
});

afterAll(() => process.chdir(cwd));

describe("a relative project root", () => {
  it("still finds the generated files the mappings miss", async () => {
    const mappings = ["./src/pool.ts"];
    await graphCli.ensureGeneratedCode(".", graphCli.generatedDir(".", mappings), "subgraph.yaml", mappings);
    expect(existsSync(path.join(project, "generated/Pool/Pool.ts"))).toBe(true);
  });
});
