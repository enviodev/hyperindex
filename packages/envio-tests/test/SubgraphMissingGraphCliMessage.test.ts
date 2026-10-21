import { beforeAll, describe, expect, it } from "vitest";

// The CLI (`envio codegen`/`start`, Rust) and the runtime (a mapping's import
// of the missing tree, TypeScript) each wrote this message, and they had come
// apart: one said `npx graph codegen`, the other `pnpm exec graph codegen`.
// Neither runs when graph-cli isn't installed, which is when the message shows:
// npx reads `graph` as a package of that name. The runtime now asks the CLI's
// code for it. Neither path is reachable without hiding npm from the process,
// so this calls both entries directly.
type GraphCli = typeof import("envio/src/subgraph/graph-cli.ts");
type Core = typeof import("envio/src/Core.res.mjs");
let graphCli: GraphCli;
let core: Core;

beforeAll(async () => {
  const { registerTsHooks } = await import("envio/src/HandlerLoader.res.mjs");
  registerTsHooks();
  graphCli = await import("envio/src/subgraph/graph-cli.ts");
  core = await import("envio/src/Core.res.mjs");
});

describe("the missing graph-cli message", () => {
  it("is one text, from the CLI and from the runtime", () => {
    const expected =
      'Envio Subgraph needs the project\'s generated code, but "src/types/" is\n' +
      "missing and @graphprotocol/graph-cli isn't installed in the project or any\n" +
      "directory above it. Install the project's dependencies and try again:\n" +
      "  npm install   (or yarn / pnpm install)\n" +
      "Or generate manually:\n" +
      "  npx @graphprotocol/graph-cli codegen --output-dir src/types";
    expect({
      cli: core.subgraphMissingGraphCliMessage("src/types"),
      runtime: graphCli.missingGeneratedCode("/project", "/project/src/types").message,
    }).toEqual({ cli: expected, runtime: expected });
  });
});
