/**
 * CLI Subprocess Tests
 *
 * Drives the real envio binary against fixture projects that have no codegen
 * output — every command here parses the project files directly.
 */

import { describe, it, expect } from "vitest";
import fs from "fs";
import os from "os";
import path from "path";
import { runCommand } from "../utils/process.js";
import { config } from "../config.js";

const PROJECT_DIR = path.join(config.rootDir, "packages/e2e-tests/fixtures/cli-project");

// Its own schema, so setup/down can't wipe a schema another test file is
// indexing into while the suite runs in parallel.
const PG_SCHEMA = `envio_test_${Date.now()}_${process.pid}_dbmigrate`;

const runEnvio = (args: string[], env?: Record<string, string>, cwd = PROJECT_DIR) =>
  runCommand(config.envioCommand, [...config.envioArgs, ...args], {
    cwd,
    timeout: 30_000,
    env,
  });

describe("envio config view", () => {
  it("prints the resolved config as JSON", async () => {
    const result = await runEnvio(["config", "view"]);

    expect({ exitCode: result.exitCode, parsed: JSON.parse(result.stdout) }).toEqual({
      exitCode: 0,
      parsed: { version: "0.0.1-dev", storage: { postgres: true } },
    });
  });
});

// Regression test for db-migrate setup/down hanging after the postgres pool's
// idle TCP sockets kept Node's event loop alive. The commands must exit on
// their own, well within the timeout.
describe("envio local db-migrate", () => {
  const dbEnv = {
    ENVIO_PG_PORT: String(config.pgPort),
    ENVIO_PG_SCHEMA: PG_SCHEMA,
    // Hasura isn't reachable in the test environment; without this, retries
    // dominate runtime and obscure whether the process actually exited.
    ENVIO_HASURA: "false",
  };

  it("setup exits cleanly without hanging", async () => {
    const result = await runEnvio(["local", "db-migrate", "setup"], dbEnv);

    expect(result.exitCode, result.stderr).toBe(0);
  });

  it("down exits cleanly without hanging", async () => {
    const result = await runEnvio(["local", "db-migrate", "down"], dbEnv);

    expect(result.exitCode, result.stderr).toBe(0);
  });
});

// The template READMEs don't list prerequisites, so a missing one has to say
// what to install.
describe("Missing prerequisites", () => {
  it("names an unsupported Node.js and how to get a newer one", async () => {
    const preload = path.join(config.rootDir, "packages/e2e-tests/fixtures/preload/node-22.14.mjs");
    const result = await runEnvio(["start"], { NODE_OPTIONS: `--import=${preload}` });

    expect({ exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr }).toEqual({
      exitCode: 1,
      stdout: "",
      stderr: [
        "envio needs Node.js 22.15.0 or newer, and this is Node.js 22.14.0.",
        "Install a newer one from https://nodejs.org/en/download, or with your version manager, for example: nvm install --lts",
        "",
      ].join("\n"),
    });
  });

  // No container engine answers: every socket envio probes is missing, and
  // nothing listens on the Postgres port, so `envio dev` needs one.
  const startDevWithoutContainers = async (pathDirs: string[]) => {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), "envio-no-docker-"));
    return runEnvio(["dev"], {
      HOME: home,
      // A run from the repo would otherwise rebuild the addon with cargo, which
      // this HOME and PATH don't reach. A published envio ignores it.
      ENVIO_DEV_ADDON: path.join(config.rootDir, "target/debug/envio.node"),
      XDG_RUNTIME_DIR: home,
      DOCKER_HOST: `unix://${home}/docker.sock`,
      CONTAINER_HOST: `unix://${home}/podman.sock`,
      PATH: pathDirs.join(path.delimiter),
      ENVIO_PG_PORT: "1",
      ENVIO_HASURA: "false",
      ENVIO_TUI: "false",
    }).finally(() => fs.rmSync(home, { recursive: true, force: true }));
  };

  // The PATH without its Docker and Podman, plus a folder with the named
  // executables.
  const pathWith = (executables: Record<string, string>) => {
    const bin = fs.mkdtempSync(path.join(os.tmpdir(), "envio-path-"));
    for (const [name, script] of Object.entries(executables)) {
      fs.writeFileSync(path.join(bin, name), script, { mode: 0o755 });
    }
    const dirs = (process.env.PATH ?? "")
      .split(path.delimiter)
      .filter((dir) => !["docker", "podman"].some((name) => fs.existsSync(path.join(dir, name))));
    return { bin, dirs: [bin, ...dirs] };
  };

  it("says to install Docker or Podman when neither is installed", async () => {
    const { bin, dirs } = pathWith({});
    const result = await startDevWithoutContainers(dirs).finally(() =>
      fs.rmSync(bin, { recursive: true, force: true })
    );

    expect({
      exitCode: result.exitCode,
      explains: `${result.stdout}${result.stderr}`.includes(
        [
          "Neither Docker nor Podman is installed, and envio needs one to run Postgres and Hasura locally.",
          "Install Docker Desktop (https://www.docker.com/products/docker-desktop/) or Podman (https://podman.io/), then run this again.",
          "To use a Postgres you run yourself instead, set ENVIO_PG_HOST.",
        ].join("\n")
      ),
    }).toEqual({ exitCode: 1, explains: true });
  });

  it("says to start Docker when it's installed but not running", async () => {
    const { bin, dirs } = pathWith({ docker: "#!/bin/sh\nexit 1\n" });
    const result = await startDevWithoutContainers(dirs).finally(() =>
      fs.rmSync(bin, { recursive: true, force: true })
    );

    expect({
      exitCode: result.exitCode,
      explains: `${result.stdout}${result.stderr}`.includes(
        "Docker or Podman is installed but isn't running, so envio can't start Postgres and Hasura."
      ),
    }).toEqual({ exitCode: 1, explains: true });
  });
});

describe("TypeScript handler errors", () => {
  it("name the handler's TypeScript source line", async () => {
    const result = await runEnvio(
      ["start"],
      {
        ENVIO_PG_PORT: String(config.pgPort),
        ENVIO_PG_SCHEMA: `envio_test_${Date.now()}_${process.pid}_tshandler`,
        ENVIO_HASURA: "false",
      },
      path.join(config.rootDir, "packages/e2e-tests/fixtures/ts-handler-project")
    );

    expect(`${result.stdout}${result.stderr}`).toMatch(/Throwing\.ts:9:/);
  });
});

describe("TypeScript handler type check", () => {
  const fixtureDir = path.join(config.rootDir, "packages/e2e-tests/fixtures/ts-typecheck-project");
  const fixtureTsconfig = fs.readFileSync(path.join(fixtureDir, "tsconfig.json"), "utf8");
  const e2eModules = path.join(config.rootDir, "packages/e2e-tests/node_modules");

  // The type-error fixture, outside the repo so no parent folder has a
  // tsconfig.json or a typescript package. Its `typescript` is one of the
  // versions e2e-tests installs under an alias.
  const startTypeCheckProject = async ({
    typescript = "typescript",
    copyTypescript = false,
    tsconfig = fixtureTsconfig,
    files = {},
  }: {
    typescript?: string;
    // A copy can't resolve the packages installed beside the original, so
    // TypeScript 7 finds no native compiler, as after an install that skipped
    // optional dependencies.
    copyTypescript?: boolean;
    tsconfig?: string | null;
    files?: Record<string, string>;
  }) => {
    const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "envio-typecheck-"));
    fs.cpSync(fixtureDir, projectDir, {
      recursive: true,
      filter: (source) => path.basename(source) !== "tsconfig.json",
    });
    for (const [name, contents] of Object.entries({
      "package.json": '{"type":"module"}',
      ...(tsconfig === null ? {} : { "tsconfig.json": tsconfig }),
      ...files,
    })) {
      fs.writeFileSync(path.join(projectDir, name), contents);
    }
    const modules = path.join(projectDir, "node_modules");
    fs.mkdirSync(modules);
    for (const name of fs.readdirSync(e2eModules)) {
      if (!name.startsWith("typescript") && name !== ".bin") {
        fs.symlinkSync(path.join(e2eModules, name), path.join(modules, name));
      }
    }
    const typescriptDir = fs.realpathSync(path.join(e2eModules, typescript));
    if (copyTypescript) {
      fs.cpSync(typescriptDir, path.join(modules, "typescript"), { recursive: true });
    } else {
      fs.symlinkSync(typescriptDir, path.join(modules, "typescript"));
    }

    const before = fs.readdirSync(projectDir);
    let written: string[] = [];
    const result = await runEnvio(
      ["start"],
      {
        ENVIO_PG_PORT: String(config.pgPort),
        ENVIO_PG_SCHEMA: `envio_test_${Date.now()}_${process.pid}_typecheck`,
        ENVIO_HASURA: "false",
      },
      projectDir
    ).finally(() => {
      // What the start itself generates aside, the check writes nothing.
      written = fs
        .readdirSync(projectDir)
        .filter((name) => !before.includes(name) && name !== ".envio" && name !== "envio-env.d.ts");
      fs.rmSync(projectDir, { recursive: true, force: true });
    });
    const output = `${result.stdout}${result.stderr}`;
    return {
      exitCode: result.exitCode,
      // A log message ends where the logger resets its color.
      typeErrors: output.match(/Handler files have type errors:[^\x1b]*/)?.[0] ?? null,
      warning: output.match(/Skipped the handler type check[^\x1b]*/)?.[0] ?? null,
      loadedHandlers: output.includes("handler loaded"),
      written,
    };
  };

  const expectedType =
    "The expected type comes from property 'id' which is declared here on type '{ readonly id: string; readonly owner: string; readonly displayName: string; readonly imageUrl: string; }'";
  // The report is what the project's own tsc prints, and TypeScript 7 puts a
  // related location's message beside it rather than under its code.
  const typeErrors = (typescript: string) =>
    [
      "Handler files have type errors:",
      "",
      "src/handlers/Gravatar.ts:5:5 - error TS2322: Type 'bigint' is not assignable to type 'string'.",
      "",
      "5     id: event.params.id,",
      "      ~~",
      "",
      ...(typescript === "typescript-7"
        ? [`  .envio/types.d.ts:645:14 - ${expectedType}`, '    645     readonly "id": string;', "                     ~~~~"]
        : ["  .envio/types.d.ts:645:14", '    645     readonly "id": string;', "                     ~~~~", `    ${expectedType}`]),
    ].join("\n");

  // https://github.com/enviodev/hyperindex/issues/1684
  it.each(["typescript-5", "typescript", "typescript-7"])(
    "stops the start before handlers load with %s, reporting only handler files",
    async (typescript) => {
      expect(await startTypeCheckProject({ typescript })).toEqual({
        exitCode: 1,
        typeErrors: typeErrors(typescript),
        warning: null,
        loadedHandlers: false,
        written: [],
      });
    }
  );

  it.each(["typescript-5", "typescript", "typescript-7"])(
    "checks a composite project with %s without writing its build info",
    async (typescript) => {
      const tsconfig = fixtureTsconfig.replace('"noEmit": true', '"composite": true, "outDir": "dist"');

      expect(await startTypeCheckProject({ typescript, tsconfig })).toEqual({
        exitCode: 1,
        typeErrors: typeErrors(typescript),
        warning: null,
        loadedHandlers: false,
        written: [],
      });
    }
  );

  it.each(["typescript-5", "typescript", "typescript-7"])(
    "loads type-correct handlers with %s when the tsconfig.json explains its files",
    async (typescript) => {
      const tsconfig = fixtureTsconfig.replace('"noEmit": true', '"noEmit": true, "explainFiles": true');
      const handler = fs
        .readFileSync(path.join(fixtureDir, "src/handlers/Gravatar.ts"), "utf8")
        .replace("id: event.params.id,", "id: event.params.id.toString(),");

      expect(
        await startTypeCheckProject({ typescript, tsconfig, files: { "src/handlers/Gravatar.ts": handler } })
      ).toEqual({
        exitCode: 1,
        typeErrors: null,
        warning: null,
        loadedHandlers: true,
        written: [],
      });
    }
  );

  // tsc type-checks nothing once any file has a syntax error, so the handler's
  // type error would otherwise go unreported.
  it.each(["typescript-5", "typescript", "typescript-7"])(
    "is skipped with the reason when a syntax error stops %s from type-checking",
    async (typescript) => {
      const result = await startTypeCheckProject({
        typescript,
        files: { "src/lib/broken.ts": "export const broken = ;\n" },
      });

      expect(result).toEqual({
        exitCode: 1,
        typeErrors: null,
        warning: [
          "Skipped the handler type check: tsc reported errors that can stop it from type-checking the handlers:",
          "",
          "src/lib/broken.ts:1:23 - error TS1109: Expression expected.",
          "",
          "1 export const broken = ;",
          "                        ~",
        ].join("\n"),
        loadedHandlers: true,
        written: [],
      });
    }
  );

  // TypeScript 6 deprecates `baseUrl` and 7 removes it, and either error stops
  // tsc from type-checking.
  it.each([
    [
      "typescript",
      [
        `tsconfig.json:22:21 - error TS5101: Option 'baseUrl' is deprecated and will stop functioning in TypeScript 7.0. Specify compilerOption '"ignoreDeprecations": "6.0"' to silence this error.`,
        "  Visit https://aka.ms/ts6 for migration information.",
      ],
    ],
    [
      "typescript-7",
      [
        "tsconfig.json:22:21 - error TS5102: Option 'baseUrl' has been removed. Please remove it from your configuration.",
        `  Use '"paths": {"*": ["./*"]}' instead.`,
      ],
    ],
  ])("is skipped with the reason when an option stops %s from type-checking", async (typescript, error) => {
    const tsconfig = fixtureTsconfig.replace('"noEmit": true', '"noEmit": true, "baseUrl": "."');

    expect(await startTypeCheckProject({ typescript, tsconfig })).toEqual({
      exitCode: 1,
      typeErrors: null,
      warning: [
        "Skipped the handler type check: tsc reported errors that can stop it from type-checking the handlers:",
        "",
        ...error,
        "",
        '22     "noEmit": true, "baseUrl": ".",',
        "                       ~~~~~~~~~",
      ].join("\n"),
      loadedHandlers: true,
      written: [],
    });
  });

  it.each(["typescript-5", "typescript", "typescript-7"])(
    "names the handlers %s doesn't check because the tsconfig.json leaves them out",
    async (typescript) => {
      const tsconfig = fixtureTsconfig.replace("{", '{ "include": ["src/types.ts"],');

      expect(await startTypeCheckProject({ typescript, tsconfig })).toEqual({
        exitCode: 1,
        typeErrors: null,
        warning: "Skipped the handler type check for src/handlers/Gravatar.ts: tsconfig.json doesn't include it.",
        loadedHandlers: true,
        written: [],
      });
    }
  );

  it("is skipped with the reason when TypeScript 7 is missing its native compiler", async () => {
    const result = await startTypeCheckProject({ typescript: "typescript-7", copyTypescript: true });

    expect(result).toEqual({
      exitCode: 1,
      typeErrors: null,
      warning: [
        "Skipped the handler type check: TypeScript's tsc failed without reporting a type error:",
        "",
        `Error: Unable to resolve @typescript/typescript-${process.platform}-${process.arch}. Either your platform is unsupported, or you are missing the package on disk.`,
      ].join("\n"),
      loadedHandlers: true,
      written: [],
    });
  });

  it("is skipped with a pointer to tsconfig.json when the project has none", async () => {
    const result = await startTypeCheckProject({ tsconfig: null });

    expect(result).toEqual({
      exitCode: 1,
      typeErrors: null,
      warning:
        "Skipped the handler type check: no tsconfig.json found. Add one to type-check handlers on start, like the one envio init creates.",
      loadedHandlers: true,
      written: [],
    });
  });

  it("is skipped quietly in a ReScript project, whose handlers the ReScript compiler checks", async () => {
    const result = await startTypeCheckProject({ tsconfig: null, files: { "rescript.json": '{"name":"indexer"}' } });

    expect(result).toEqual({ exitCode: 1, typeErrors: null, warning: null, loadedHandlers: true, written: [] });
  });
});

// The tsconfig is the one found from the working directory, as tsx does, so
// this runs the CLI rather than an in-process indexer.
describe("TypeScript project config", () => {
  it("follow the tsconfig: paths and baseUrl before packages, verbatimModuleSyntax and experimentalDecorators", async () => {
    const result = await runEnvio(
      ["start"],
      {
        ENVIO_PG_PORT: String(config.pgPort),
        ENVIO_PG_SCHEMA: `envio_test_${Date.now()}_${process.pid}_tspaths`,
        ENVIO_HASURA: "false",
      },
      path.join(config.rootDir, "packages/e2e-tests/fixtures/ts-paths-project")
    );

    expect(`${result.stdout}${result.stderr}`).toContain(
      "loaded Gravatar NewGravatar shadowed cjs js side-effect decorated METHOD"
    );
  });
});
