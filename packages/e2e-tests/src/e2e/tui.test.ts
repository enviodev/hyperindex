/**
 * The progress display as a person sees it: the real CLI in a real
 * pseudo-terminal, its output replayed through a terminal emulator. Covers
 * what no unit test can: that logs land above the display and stay in the
 * scrollback, that every redraw erases the last one, and that Ctrl-C leaves
 * the final frame and the cursor behind.
 *
 * Each run also saves the final screen as an SVG under `.artifacts/tui`, so a
 * change to the display can be looked at, not just asserted on, along with the
 * raw bytes the terminal received.
 *
 * Needs Postgres and ClickHouse but no Docker: it drives `envio start` with
 * Hasura disabled.
 */

import { describe, it, expect, beforeAll } from "vitest";
import fs from "fs";
import path from "path";
import { config } from "../config.js";
import { runCommand } from "../utils/process.js";
import { isPgReachable } from "../utils/pg-direct.js";
import { isClickHouseReachable } from "../utils/clickhouse.js";
import {
  replay,
  runInPty,
  toSvg,
  waitForScreen,
  type Screen,
} from "../utils/terminal.js";

const SIZE = { cols: 100, rows: 40 };
const ARTIFACTS_DIR = path.join(
  config.rootDir,
  "packages/e2e-tests/.artifacts/tui",
);

const reachable = (await isPgReachable()) && (await isClickHouseReachable());

if (!reachable && process.env.CI) {
  throw new Error(
    "Postgres or ClickHouse is unreachable, so the TUI suite cannot run. Refusing to skip it in CI.",
  );
}

const baseEnv = (): Record<string, string> => {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    const lower = key.toLowerCase();
    if (
      value === undefined ||
      lower.startsWith("npm_") ||
      lower.startsWith("pnpm_")
    )
      continue;
    env[key] = value;
  }
  // The display's own decision is what's under test, so nothing decides it for it.
  delete env.CI;
  delete env.CLAUDECODE;
  return {
    ...env,
    TERM: "xterm-256color",
    COLORTERM: "truecolor",
    ENVIO_HASURA: "false",
    ENVIO_INDEXER_PORT: "9895",
    ENVIO_API_TOKEN: process.env.ENVIO_API_TOKEN ?? "",
  };
};

const isTitle = (line: string) => line.startsWith("  envio@");

/** The display: from the title to the end of the screen. */
const frameOf = (screen: Screen) =>
  screen.lines
    .slice(screen.lines.findLastIndex(isTitle))
    .map((line) =>
      line
        .replace(/^  envio@\S+ .*\/([^/]+)$/, "  envio@<version> …/$1")
        .replace(/^  ✓ synced in .+? · /, "  ✓ synced in <elapsed> · "),
    );

const LOGO = [
  "                                     ⢕⠕⠑⠑ ⢕⢕⠄ ⢕⠅⠐⢕  ⢔⠕⢐⢕ ⢀⠔⠕⠕⢔⠄",
  "                                     ⢕⠕⠔⠔ ⢕⠕⢕⢄⢕⠅ ⢑⢅⢐⠕ ⢐⢕ ⢕⠅  ⢐⢕",
  "                                     ⢕⢕⢔⢔⠄⢕⠅ ⠑⢕⠅  ⢕⢕⠁ ⢐⢕ ⠑⢕⢔⢔⠕⠁",
];

const READY = "Ready. Fully indexed for queries.";

/** Synced, and every chain's last log is out, so nothing prints after Ctrl-C. */
const isDone = (chains: number) => (screen: Screen) =>
  frameOf(screen).some((line) => line.startsWith("  ✓ synced in <elapsed>")) &&
  screen.lines.filter((line) => line.includes(READY)).length === chains;

async function runToSyncedAndInterrupt(
  name: string,
  projectDir: string,
  chains: number,
  env: Record<string, string>,
) {
  const run = runInPty(
    config.envioCommand,
    [...config.envioArgs, "start", "-r"],
    {
      cwd: projectDir,
      env: { ...baseEnv(), ...env },
      size: SIZE,
    },
  );
  await waitForScreen(run, SIZE, isDone(chains), 90_000);
  run.type("\x03");
  const exitCode = await run.exited;
  const screen = await replay(run.output(), SIZE);
  fs.mkdirSync(ARTIFACTS_DIR, { recursive: true });
  fs.writeFileSync(path.join(ARTIFACTS_DIR, `${name}.svg`), toSvg(screen));
  fs.writeFileSync(path.join(ARTIFACTS_DIR, `${name}.raw`), run.output());
  return { exitCode, screen };
}

const codegen = async (projectDir: string) => {
  const result = await runCommand(
    config.envioCommand,
    [...config.envioArgs, "codegen"],
    {
      cwd: projectDir,
      timeout: config.timeouts.codegen,
    },
  );
  expect(result.exitCode, `codegen failed: ${result.stderr}`).toBe(0);
};

describe.skipIf(!reachable)("E2E: TUI", () => {
  const singleDir = path.join(config.scenariosDir, "e2e_test");
  const splitDir = path.join(config.scenariosDir, "split_test");

  beforeAll(async () => {
    await codegen(singleDir);
    await codegen(splitDir);
  });

  it("draws below the logs of a single process and leaves the final frame on Ctrl-C", async () => {
    const { exitCode, screen } = await runToSyncedAndInterrupt(
      "single-process",
      singleDir,
      1,
      {
        ENVIO_PG_SCHEMA: "e2e_tui",
        ENVIO_CLICKHOUSE_HOST: config.clickhouseUrl,
        ENVIO_CLICKHOUSE_USERNAME: config.clickhouseUsername,
        ENVIO_CLICKHOUSE_PASSWORD: config.clickhousePassword,
        ENVIO_CLICKHOUSE_DATABASE: "e2e_tui",
        E2E_EXPECTED_END_BLOCK: "10861774",
      },
    );
    expect({
      exitCode,
      cursorVisible: screen.cursorVisible,
      frames: screen.lines.filter(isTitle).length,
      linesAfterReady:
        screen.lines.length -
        screen.lines.findLastIndex((line) => line.includes(READY)),
      frame: frameOf(screen),
    }).toEqual({
      exitCode: 130,
      cursorVisible: true,
      frames: 1,
      // The log's own trailing blank line, then the frame.
      linesAfterReady: 14,
      frame: [
        "  envio@<version> …/e2e_test",
        "",
        ...LOGO,
        "",
        "  Ethereum 1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ✓  at end 10,861,774 2 events",
        "",
        "  ✓ synced in <elapsed> · 2 events",
        "",
        `  GraphQL http://localhost:8080 (admin secret: testing)   ClickHouse ${config.clickhouseUrl}/play`,
      ],
    });
  });

  it("draws for every worker of a split run from the supervisor", async () => {
    const { exitCode, screen } = await runToSyncedAndInterrupt(
      "supervisor",
      splitDir,
      2,
      {
        ENVIO_PG_SCHEMA: "e2e_tui_split",
        // Two processes' worth, so the run splits.
        ENVIO_PG_MAX_CONNECTIONS: "4",
      },
    );
    expect({
      exitCode,
      cursorVisible: screen.cursorVisible,
      frames: screen.lines.filter(isTitle).length,
      frame: frameOf(screen),
    }).toEqual({
      exitCode: 0,
      cursorVisible: true,
      frames: 1,
      frame: [
        "  envio@<version> …/split_test",
        "",
        ...LOGO,
        "",
        "  Ethereum 1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ✓  at end 10,861,774  2 events",
        "  Base 8453  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ✓  at end 10,000,050 53 events",
        "",
        "  ✓ synced in <elapsed> · 55 events",
        "",
        "  GraphQL http://localhost:8080 (admin secret: testing)",
      ],
    });
  });
});
