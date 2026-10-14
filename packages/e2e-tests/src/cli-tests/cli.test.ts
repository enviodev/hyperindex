/**
 * CLI Subprocess Tests
 *
 * Drives the real envio binary against fixture projects that have no codegen
 * output — every command here parses the project files directly.
 */

import { describe, it, expect } from "vitest";
import fs from "fs";
import http from "http";
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
    // `null` leaves typescript uninstalled.
    typescript?: string | null;
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
    if (typescript !== null) {
      const typescriptDir = fs.realpathSync(path.join(e2eModules, typescript));
      if (copyTypescript) {
        fs.cpSync(typescriptDir, path.join(modules, "typescript"), { recursive: true });
      } else {
        fs.symlinkSync(typescriptDir, path.join(modules, "typescript"));
      }
    }

    const before = fs.readdirSync(projectDir);
    let written: string[] = [];
    const result = await runEnvio(
      ["start"],
      {
        ENVIO_PG_PORT: String(config.pgPort),
        ENVIO_PG_SCHEMA: `envio_test_${Date.now()}_${process.pid}_typecheck`,
        ENVIO_HASURA: "false",
        // A globally installed typescript would otherwise resolve.
        NODE_PATH: "",
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
      typeErrors: output.match(/The handler type check found errors[^\x1b]*/)?.[0] ?? null,
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
      "The handler type check found errors. Fix them to start the indexer:",
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
          "Skipped the handler type check: tsc can't check the handlers until these errors are fixed:",
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
        "Skipped the handler type check: tsc can't check the handlers until these errors are fixed:",
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
        warning:
          'Skipped the handler type check: tsconfig.json doesn\'t include src/handlers/Gravatar.ts. Add it to "include" to type-check it on start.',
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
        "Skipped the handler type check: tsc failed to run:",
        "",
        `Error: Unable to resolve @typescript/typescript-${process.platform}-${process.arch}. Either your platform is unsupported, or you are missing the package on disk.`,
      ].join("\n"),
      loadedHandlers: true,
      written: [],
    });
  });

  it("is skipped with how to install typescript when the project has none", async () => {
    const result = await startTypeCheckProject({ typescript: null });

    expect(result).toEqual({
      exitCode: 1,
      typeErrors: null,
      warning:
        "Skipped the handler type check: typescript isn't installed. Add it to devDependencies to type-check handlers on start.",
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
        "Skipped the handler type check: no tsconfig.json found. Add one, like the one envio init creates, to type-check handlers on start.",
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

// A development build sends nothing unless ENVIO_TELEMETRY_ENDPOINT is set, so
// these run the real CLI in debug mode or against a local endpoint.
describe("Telemetry", () => {
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
  const DEBUG_HEADER = "envio telemetry (debug mode, not sent):";

  // Its own config directory and a copy of the project, so a run reads no
  // setting it didn't write and leaves no id in the fixture.
  const isolated = async <T>(run: (dirs: { configHome: string; project: string }) => Promise<T>) => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "envio-telemetry-"));
    const configHome = path.join(root, "config");
    const project = path.join(root, "project");
    fs.mkdirSync(configHome);
    fs.cpSync(PROJECT_DIR, project, { recursive: true });
    return run({ configHome, project }).finally(() => fs.rmSync(root, { recursive: true, force: true }));
  };

  const debugBatch = (stderr: string) =>
    stderr.includes(DEBUG_HEADER) ? JSON.parse(stderr.slice(stderr.indexOf(DEBUG_HEADER) + DEBUG_HEADER.length)) : null;

  const context = {
    install_id: expect.stringMatching(UUID),
    session_id: expect.stringMatching(UUID),
    envio_version: "0.0.1-dev",
    os: expect.any(String),
    arch: expect.any(String),
    node_major: expect.any(Number),
    ci: expect.any(Boolean),
    environment: expect.stringMatching(/^(local|docker|kubernetes)$/),
    // Whichever agent runs this suite, if any.
    agent: expect.stringMatching(/^(claude|codex|cursor|none)$/),
  };

  it("prints a command's event in debug mode, and stores nothing", async () => {
    const result = await isolated(async ({ configHome, project }) => {
      const run = await runEnvio(
        ["config", "view"],
        { XDG_CONFIG_HOME: configHome, ENVIO_TELEMETRY_DEBUG: "1" },
        project
      );
      return {
        exitCode: run.exitCode,
        version: JSON.parse(run.stdout).version,
        batch: debugBatch(run.stderr),
        stored: [fs.readdirSync(configHome), fs.existsSync(path.join(project, ".envio", "telemetry"))],
      };
    });

    expect(result).toEqual({
      exitCode: 0,
      version: "0.0.1-dev",
      batch: {
        schema_version: 1,
        context,
        events: [
          {
            type: "command",
            indexer_id: expect.stringMatching(UUID),
            command: "config_view",
            outcome: "success",
            error_class: null,
            duration: expect.any(String),
          },
        ],
      },
      stored: [[], false],
    });
  });

  it("reports a failed command with its class and no indexer id outside a project", async () => {
    const result = await isolated(async ({ configHome }) => {
      const run = await runEnvio(
        ["codegen"],
        { XDG_CONFIG_HOME: configHome, ENVIO_TELEMETRY_DEBUG: "1" },
        configHome
      );
      return { exitCode: run.exitCode, events: debugBatch(run.stderr)?.events };
    });

    expect(result).toEqual({
      exitCode: 1,
      events: [
        {
          type: "command",
          indexer_id: null,
          command: "codegen",
          outcome: "failure",
          error_class: "config",
          duration: expect.any(String),
        },
      ],
    });
  });

  // Without a TTY, a bare `envio init` prints its steps for an agent and stops
  // before any choice is made.
  it("reports an init that took the agentic path", async () => {
    const result = await isolated(async ({ configHome }) => {
      const run = await runEnvio(["init"], { XDG_CONFIG_HOME: configHome, ENVIO_TELEMETRY_DEBUG: "1" }, configHome);
      return { exitCode: run.exitCode, batch: debugBatch(run.stderr) };
    });

    expect(result).toEqual({
      exitCode: 2,
      batch: {
        schema_version: 1,
        context,
        events: [
          {
            type: "command",
            indexer_id: null,
            command: "init",
            outcome: "agent_prompt",
            error_class: null,
            duration: expect.any(String),
            init: { agentic: true, ecosystem: null, flow: null, template: null, language: null },
          },
        ],
      },
    });
  });

  it("is silenced by DO_NOT_TRACK, ENVIO_TELEMETRY_DISABLED and `envio telemetry disable`, even in debug mode", async () => {
    const result = await isolated(async ({ configHome, project }) => {
      const debug = { XDG_CONFIG_HOME: configHome, ENVIO_TELEMETRY_DEBUG: "1" };
      const doNotTrack = await runEnvio(["config", "view"], { ...debug, DO_NOT_TRACK: "1" }, project);
      const disabled = await runEnvio(["config", "view"], { ...debug, ENVIO_TELEMETRY_DISABLED: "1" }, project);
      const disable = await runEnvio(["telemetry", "disable"], debug, project);
      const afterDisable = await runEnvio(["config", "view"], debug, project);
      const status = await runEnvio(["telemetry", "status"], debug, project);
      return {
        stderr: [doNotTrack.stderr, disabled.stderr, afterDisable.stderr],
        disable: disable.exitCode,
        stored: JSON.parse(fs.readFileSync(path.join(configHome, "envio", "telemetry.json"), "utf8")),
        status: status.stdout.split("\n")[0],
      };
    });

    expect(result).toEqual({
      stderr: ["", "", ""],
      disable: 0,
      stored: { enabled: false, notice_shown: true },
      status: "Telemetry is off: turned off with `envio telemetry disable`. Nothing is sent.",
    });
  });

  it("status shows the heartbeat this project would send", async () => {
    const run = await isolated(({ configHome, project }) =>
      runEnvio(["telemetry", "status"], { XDG_CONFIG_HOME: configHome }, project)
    );
    const heartbeat = run.stdout.slice(run.stdout.indexOf("{", run.stdout.indexOf("A running indexer")));

    expect({
      exitCode: run.exitCode,
      firstLine: run.stdout.split("\n")[0],
      heartbeat: JSON.parse(heartbeat.slice(0, heartbeat.lastIndexOf("}") + 1)).events,
    }).toEqual({
      exitCode: 0,
      firstLine:
        "Telemetry is off: this is a development build of envio, which never sends anything unless ENVIO_TELEMETRY_ENDPOINT is set. Nothing is sent.",
      heartbeat: [
        {
          type: "heartbeat",
          indexer_id: expect.stringMatching(UUID),
          reason: "start",
          ecosystem: "evm",
          language: "typescript",
          chains: [{ chain_id: 1, sources: ["hypersync"] }],
          contracts: 1,
          events: 1,
          entities: expect.any(Number),
          storage: ["postgres"],
          features: [],
          sync_state: "backfilling",
          uptime: "0-1h",
          events_processed: "0",
          errors: {},
        },
      ],
    });
  });

  // An endpoint that takes the request and never answers: a command that waited
  // on it would exit 2s after it connected, when the first attempt times out.
  it("sends from a detached process, so a command never waits on the endpoint", async () => {
    const received: { at: number; body: string }[] = [];
    const server = http.createServer((req) => {
      let body = "";
      req.on("data", (chunk) => (body += chunk));
      req.on("end", () => received.push({ at: Date.now(), body }));
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const { port } = server.address() as { port: number };

    try {
      const result = await isolated(async ({ configHome, project }) => {
        const run = await runEnvio(
          ["config", "view"],
          { XDG_CONFIG_HOME: configHome, ENVIO_TELEMETRY_ENDPOINT: `http://127.0.0.1:${port}/v1/hyperindex` },
          project
        );
        const exitedAt = Date.now();
        for (let waited = 0; received.length === 0 && waited < 10_000; waited += 50) {
          await new Promise((resolve) => setTimeout(resolve, 50));
        }
        const first = received[0];
        return {
          exitCode: run.exitCode,
          notice: run.stderr.split("\n")[0],
          exitedBeforeTimeout: first !== undefined && exitedAt - first.at < 1_500,
          command: first && JSON.parse(first.body).events[0].command,
          stored: Object.keys(JSON.parse(fs.readFileSync(path.join(configHome, "envio", "telemetry.json"), "utf8"))),
          indexerIdIgnored: fs.readFileSync(path.join(project, ".envio", "telemetry", ".gitignore"), "utf8"),
        };
      });

      expect(result).toEqual({
        exitCode: 0,
        notice: "Envio collects anonymous usage data to improve HyperIndex: which commands and",
        exitedBeforeTimeout: true,
        command: "config_view",
        stored: ["install_id", "notice_shown"],
        indexerIdIgnored: "*\n",
      });
    } finally {
      server.closeAllConnections();
      server.close();
    }
  });
});
