import { deepEqual } from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { findMissingDocPaths } from "./rules/docReferences.ts";
import { findFakedTimers } from "./rules/fakeTimers.ts";
import { findUnnamedHeightWaits } from "./rules/heightCalls.ts";
import { findUnannotatedMagic } from "./rules/magicAnnotation.ts";
import { findLogicInMigratedDirectories } from "./rules/migratedToRust.ts";
import { findGuessedWaits } from "./rules/mockSteps.ts";
import { findPerformanceReads } from "./rules/performanceReads.ts";
import { findRawFieldPaths } from "./rules/rawFieldPath.ts";
import { findUnsetDurations } from "./rules/reportedDurations.ts";
import { summarizeRescriptDirection } from "./rules/rescriptDirection.ts";
import type { file } from "./rules/shared.ts";
import { findRealClockInSources } from "./rules/sourceClock.ts";
import { findLoggingInTests } from "./rules/testLogging.ts";
import { findRealTimeOnVirtualTime } from "./rules/virtualTime.ts";

const fileOf = (path: string, ...lines: string[]): file => ({ path, text: lines.join("\n") });

test("a zero delay or a poll ahead of a mock step", () => {
  const bad = [
    fileOf(
      "packages/envio-tests/test/Guess_test.res",
      "await Utils.delay(0)",
      "// A comment between the two hides nothing.",
      "await mock.expectItemsQueries([])",
      "await Utils.delay(0)",
      "mock.resolveGetHeightOrThrow(300)",
      "while mock.pendingItemsQueries()->Array.length === 0 {",
      "  ()",
      "}",
    ),
  ];
  const good = [
    fileOf(
      "packages/envio-tests/test/Guess_test.res",
      "await Utils.delay(0)",
      "let value = compute()",
      "await mock.expectItemsQueries([])",
    ),
  ];
  deepEqual(
    { bad: findGuessedWaits(bad), good: findGuessedWaits(good) },
    {
      bad: [
        {
          file: "packages/envio-tests/test/Guess_test.res",
          line: 1,
          title: "Utils.delay(0) before expectItemsQueries",
          fix: "Delete the delay: `expectItemsQueries` waits for what it answers, or answers only what is already pending.",
        },
        {
          file: "packages/envio-tests/test/Guess_test.res",
          line: 4,
          title: "Utils.delay(0) before resolveGetHeightOrThrow",
          fix: "Delete the delay: a height answer with no call pending is held for the next call.",
        },
        {
          file: "packages/envio-tests/test/Guess_test.res",
          line: 6,
          title: "Polling pendingItemsQueries",
          fix: "Replace the poll with `await mock.expectItemsQueries([...])` naming the queries (`reply: LeavePending` for ones answered later).",
        },
      ],
      good: [],
    },
  );
});

test("real time in a scenario on virtual time", () => {
  const path = "packages/envio-tests/test/Timing_test.res";
  const bad = [
    fileOf(
      path,
      'let scenario = Scenario.make(~name="timing")',
      "",
      'scenario->Scenario.it("waits", ~virtualTime=true, async (~indexer, ~source) => {',
      "  await Utils.delay(50)",
      "  let startedAt = Date.now()",
      "  let before = mock.getHeightOrThrowCalls->Array.length",
      "})",
      "",
      'scenario->Scenario.it("real", ~virtualTime=false, ~sourceTiming=fast, async (~indexer, ~source) => {',
      "  ()",
      "})",
    ),
  ];
  const good = [
    fileOf(
      path,
      "// A real server answers this one.",
      'let realScenario = Scenario.make(~name="real", ~virtualTime=false)',
      "",
      'realScenario->Scenario.it("talks to the server", async (~indexer, ~source) => {',
      "  await Utils.delay(50)",
      "})",
      "",
      'let scenario = Scenario.make(~name="virtual")',
      "",
      'scenario->Scenario.it("advances", async (~indexer, ~source) => {',
      "  await indexer.advanceTime(50)",
      "  // Real time: the handler body runs off the clock.",
      "  await Utils.delay(5)",
      "})",
    ),
  ];
  deepEqual(
    { bad: findRealTimeOnVirtualTime(bad), good: findRealTimeOnVirtualTime(good) },
    {
      bad: [
        {
          file: path,
          line: 3,
          title: "~virtualTime=true is the default",
          fix: "Delete it: scenarios run on virtual time unless they opt out.",
        },
        {
          file: path,
          line: 9,
          title: "~virtualTime=false without a reason",
          fix: "Say on the line above why this test needs real time, such as a source talking to a real server.",
        },
        {
          file: path,
          line: 4,
          title: "Utils.delay(50) on virtual time",
          fix: "Replace it with `await indexer.advanceTime(50)`: the source layer's timers only fire when the test advances the clock.",
        },
        {
          file: path,
          line: 5,
          title: "Reading the real clock on virtual time",
          fix: "Time the scenario by how far it advanced: real time says nothing about when a virtual timer fired.",
        },
        {
          file: path,
          line: 6,
          title: "Counting height calls by hand on virtual time",
          fix: "Replace the count with `await mock.expectNewHeightCalls(n)` at the step that causes the polls.",
        },
        {
          file: path,
          line: 9,
          title: "~sourceTiming on real time",
          fix: "Drop `~virtualTime=false` and drive its timers with `await indexer.advanceTime(ms)`.",
        },
      ],
      good: [],
    },
  );
});

test("a test waiting for a height call it doesn't name", () => {
  const bad = [fileOf("packages/envio-tests/test/Height_test.res", "await mock.waitForHeightCall()")];
  const good = [fileOf("packages/envio-tests/test/helpers/Scenario.res", "await mock.waitForHeightCall()")];
  deepEqual(
    { bad: findUnnamedHeightWaits(bad), good: findUnnamedHeightWaits(good) },
    {
      bad: [
        {
          file: "packages/envio-tests/test/Height_test.res",
          line: 1,
          title: "waitForHeightCall in a test",
          fix: "Name the call with `await mock.expectNewHeightCalls(n)`, or answer the first height with `Scenario.resolveInitialHeight`.",
        },
      ],
      good: [],
    },
  );
});

test("vitest's fake timers", () => {
  const bad = [fileOf("packages/envio-tests/test/Timers.test.ts", "vi.useFakeTimers();")];
  const good = [fileOf("packages/envio-tests/test/Timers.test.ts", "// vi.useFakeTimers() is refused here.")];
  deepEqual(
    { bad: findFakedTimers(bad), good: findFakedTimers(good) },
    {
      bad: [
        {
          file: "packages/envio-tests/test/Timers.test.ts",
          line: 1,
          title: "vi.useFakeTimers fakes vitest's timers",
          fix: "Move time on the clock the code was given instead: `await indexer.advanceTime(ms)` for a scenario, or a `VirtualClock` passed as the module's clock for a unit test.",
        },
      ],
      good: [],
    },
  );
});

test("the real clock in the source layer", () => {
  const onTheClock =
    "on the clock the module was given: a virtual-time scenario only sees and moves time that goes through it.";
  const bad = [
    fileOf(
      "packages/envio/src/sources/Poller.res",
      "let timer = setTimeout(() => poll(), 1000)",
      "let startedAt = Date.now()",
    ),
    fileOf("packages/envio/src/Throttler.res", "await Utils.delay(10)"),
  ];
  const good = [
    fileOf(
      "packages/envio/src/sources/Poller.res",
      'let timer = clock.setTimeout(~label="poll", () => poll(), 1000)',
    ),
    fileOf("packages/envio/src/Main.res", "let startedAt = Date.now()"),
  ];
  deepEqual(
    { bad: findRealClockInSources(bad), good: findRealClockInSources(good) },
    {
      bad: [
        {
          file: "packages/envio/src/sources/Poller.res",
          line: 1,
          title: "setTimeout(...) on the real clock",
          fix: `Use \`clock.setTimeout(~label, ...)\` and \`clock.clearTimeout\` ${onTheClock}`,
        },
        {
          file: "packages/envio/src/sources/Poller.res",
          line: 2,
          title: "Date.now(...) on the real clock",
          fix: `Use \`clock.now()\` ${onTheClock}`,
        },
        {
          file: "packages/envio/src/Throttler.res",
          line: 1,
          title: "Utils.delay(...) on the real clock",
          fix: `Use \`clock->Clock.delay(~label, millis)\` ${onTheClock}`,
        },
      ],
      good: [],
    },
  );
});

test("a reported duration timed on Performance", () => {
  const bad = [fileOf("packages/envio/src/EventProcessing.res", "let startedAt = Performance.now()")];
  const good = [
    fileOf("packages/envio/src/Storage.res", "let startedAt = Performance.now()"),
    fileOf(
      "packages/envio/src/bindings/Performance.res",
      "let secondsSince = start => (Performance.now() -. start) /. 1000.",
    ),
  ];
  deepEqual(
    { bad: findPerformanceReads(bad), good: findPerformanceReads(good) },
    {
      bad: [
        {
          file: "packages/envio/src/EventProcessing.res",
          line: 1,
          title: "Performance.now times on the real clock",
          fix: "Time it on the run's clock (`clock->Clock.readTimeRef`, then `Clock.secondsSince`), so a scenario sets the duration with `indexer.delay` and `advanceTime` and asserts it exactly.",
        },
      ],
      good: [],
    },
  );
});

test("a duration nothing set", () => {
  const path = "packages/envio-tests/test/Duration_test.res";
  const bad = [
    fileOf(
      path,
      "handler: async _ => await Utils.delay(5),",
      'Assert.ok(metric("envio_handler_seconds_total") > 0.)',
    ),
  ];
  const good = [
    fileOf(
      path,
      "handler: async _ => await indexer.delay(5),",
      "// Real time: the write goes to a real database.",
      'Assert.ok(metric("envio_storage_write_seconds_total") > 0.)',
    ),
  ];
  deepEqual(
    { bad: findUnsetDurations(bad), good: findUnsetDurations(good) },
    {
      bad: [
        {
          file: path,
          line: 1,
          title: "A handler that takes time with Utils.delay(5)",
          fix: "Wait with `await indexer.delay(5)` and let the test pass it with `await indexer.advanceTime(5)`: the handler then takes exactly that long.",
        },
        {
          file: path,
          line: 2,
          title: "A duration metric asserted as more than zero",
          fix: "Assert its exact value: make the time pass with `indexer.delay` and `advanceTime`. For a metric of real work that virtual time can't set, say why on a `// Real time:` line above.",
        },
      ],
      good: [],
    },
  );
});

test("Utils.magic without its types", () => {
  const fix =
    "Write both ends: `value->(Utils.magic: inputType => outputType)`. A bare cast takes whatever types inference hands it, so a change upstream changes what it casts and nothing fails.";
  const bad = [
    fileOf(
      "packages/envio/src/Cast.res",
      "let params: Internal.eventParams = payload->Utils.magic",
      "let cast = Utils.magic",
    ),
  ];
  const good = [
    fileOf(
      "packages/envio/src/Cast.res",
      "// Utils.magic alone in a comment is not a cast.",
      'let params = payload->(Utils.magic: {"id": bigint} => Internal.eventParams)',
      "let fields = selection->(",
      "  Utils.magic: array<Internal.evmTransactionField> => array<string>",
      ")",
    ),
    fileOf("packages/cli/templates/static/greeter/src/Handlers.res", "let params = payload->Utils.magic"),
  ];
  deepEqual(
    { bad: findUnannotatedMagic(bad), good: findUnannotatedMagic(good) },
    {
      bad: [
        { file: "packages/envio/src/Cast.res", line: 1, title: "Utils.magic without its types", fix },
        { file: "packages/envio/src/Cast.res", line: 2, title: "Utils.magic without its types", fix },
      ],
      good: [],
    },
  );
});

test("%raw naming a field path", () => {
  const path = "packages/envio-tests/test/helpers/Backend.res";
  const bad = [
    fileOf(
      path,
      "let backend = %raw(`process.env.ENVIO_TEST_STORAGE`)->Nullable.toOption",
      "let log: string => unit = %raw(`console.log`)",
    ),
  ];
  const good = [
    fileOf(
      path,
      "let log: string => unit = %raw(`message => console.log(message)`)",
      "let empty = %raw(`null`)",
      "let half = %raw(`0.5`)",
    ),
  ];
  deepEqual(
    { bad: findRawFieldPaths(bad), good: findRawFieldPaths(good) },
    {
      bad: [
        {
          file: path,
          line: 1,
          title: "%raw reading process.env.ENVIO_TEST_STORAGE",
          fix: 'Read it with `NodeJs.Process.process.env->Dict.get("ENVIO_TEST_STORAGE")`: the compiler checks a binding\'s name and type, and reads nothing inside %raw.',
        },
        {
          file: path,
          line: 2,
          title: "%raw reading console.log",
          fix: 'Bind it with `@val external name: type = "console.log"`: the compiler checks a binding\'s name and type, and reads nothing inside %raw.',
        },
      ],
      good: [],
    },
  );
});

test("logging in a test", () => {
  const fix =
    "Delete it, or assert on what it showed: nobody reads a test's output. A run's own log lines are in `indexer.infoAndAboveLogs()`.";
  const bad = [
    fileOf("packages/envio-tests/test/Noisy_test.res", "Console.log(result)", 'Js.log2("result", result)'),
  ];
  const good = [
    fileOf("packages/envio-tests/test/fixtures/ConsoleOrder.res", 'Console.log("a line")'),
    fileOf("packages/envio/src/Logger.res", "Console.log(line)"),
    fileOf("packages/envio-tests/test/Quiet_test.res", "// Console.log(result)", "TestConsole.lines()"),
  ];
  deepEqual(
    { bad: findLoggingInTests(bad), good: findLoggingInTests(good) },
    {
      bad: [
        { file: "packages/envio-tests/test/Noisy_test.res", line: 1, title: "Console.log in a test", fix },
        { file: "packages/envio-tests/test/Noisy_test.res", line: 2, title: "Js.log2 in a test", fix },
      ],
      good: [],
    },
  );
});

test("a doc naming a path that isn't there", () => {
  const fix =
    "Name where it lives now, or drop the sentence if it is gone. A path the build generates takes a placeholder, as in `<project>/.envio/types.d.ts`, and a span that is no path at all loses its backticks.";
  const tracked = [
    fileOf("packages/cli/src/lib.rs", ""),
    fileOf("packages/cli/src/config_parsing/human_config.rs", ""),
    fileOf("scenarios/test_codegen/config.yaml", ""),
  ];
  const bad = [
    ...tracked,
    fileOf(
      "CLAUDE.md",
      "- Metrics live in `packages/envio/src/Prometheus.res`.",
      "- Config is parsed by `human_config.rs`, then `system_config.rs`.",
      "- Run `pnpm vitest run test/Missing_test.res` for one file.",
      "- Templates live in `templates/`.",
    ),
    fileOf(".claude/skills/testing/SKILL.md", "See `test/helpers/Gone.res`."),
  ];
  const good = [
    ...tracked,
    fileOf(
      "CLAUDE.md",
      "- Rust CLI: `packages/cli`, entry `src/lib.rs`.",
      "- Scenario projects: `scenarios/` (`test_codegen`).",
      "- Never edit `<project>/.envio/`; logs land in `.test-logs/*.jsonl`.",
      "- `pnpm`, not `npm`. Read `.res` modules. See `Scenario.it` and `packages/cli/src/lib.rs:12`.",
      "",
      "```",
      "cd packages/nowhere",
      "```",
      "~~~",
      "`packages/nowhere/Gone.res`",
      "~~~",
    ),
    fileOf("README.md", "Not a contributor doc: `packages/nowhere/Gone.res`."),
  ];
  deepEqual(
    { bad: findMissingDocPaths(bad), good: findMissingDocPaths(good) },
    {
      bad: [
        {
          file: "CLAUDE.md",
          line: 1,
          title: "`packages/envio/src/Prometheus.res` is not a path in the repo",
          fix,
        },
        { file: "CLAUDE.md", line: 2, title: "`system_config.rs` is not a path in the repo", fix },
        { file: "CLAUDE.md", line: 4, title: "`templates/` is not a path in the repo", fix },
        {
          file: ".claude/skills/testing/SKILL.md",
          line: 1,
          title: "`test/helpers/Gone.res` is not a path in the repo",
          fix,
        },
      ],
      good: [],
    },
  );
});

test("ReScript logic in a directory that moved to Rust", () => {
  const migrated = ["packages/envio/src/sources"];
  const logic = fileOf(
    "packages/envio/src/sources/SourceManager.res",
    "let pickSource = sources => sources->Array.get(0)",
  );
  const binding = fileOf(
    "packages/envio/src/sources/ChainBuffer.res",
    "// The word external in a comment binds nothing.",
    "type t",
    '@send external make: (ctor, config) => t = "make"',
    "let emptyRegistrations = () => []",
  );
  const outside = fileOf("packages/envio/src/Main.res", "let start = () => ()");
  deepEqual(
    {
      bad: findLogicInMigratedDirectories([logic, binding, outside], migrated),
      good: findLogicInMigratedDirectories([binding, outside], migrated),
      nothingMigratedYet: findLogicInMigratedDirectories([logic, binding, outside]),
    },
    {
      bad: [
        {
          file: "packages/envio/src/sources/SourceManager.res",
          line: 1,
          title: "ReScript logic in a directory that moved to Rust",
          fix: "Write it in Rust under `packages/cli/src` and keep here only the file that binds it: every `.res` file in `packages/envio/src/sources` declares the `external`s it binds.",
        },
      ],
      good: [],
      nothingMigratedYet: [],
    },
  );
});

test("net ReScript runtime lines against the merge base", () => {
  const base = [
    fileOf("packages/envio/src/FetchState.res", "let a = 1", "", "let b = 2", "let c = 3", ""),
    fileOf("packages/envio/src/Gone.res", "let x = 1", ""),
    fileOf("packages/envio/src/Same.res", "let y = 1", ""),
    fileOf("packages/envio-tests/test/Some_test.res", "let z = 1", ""),
  ];
  const head = [
    fileOf("packages/envio/src/FetchState.res", "let a = 1", ""),
    fileOf("packages/envio/src/bindings/EventStore.res", "type t", "", '@send external make: unit => t = "make"', ""),
    fileOf("packages/envio/src/Same.res", "", "let y = 1", ""),
    fileOf("packages/envio/src/NodeVersion.mjs", "export const minimum = 22", ""),
    fileOf("packages/envio-tests/test/Some_test.res", "let z = 1", "let w = 2", ""),
  ];
  deepEqual(summarizeRescriptDirection(base, head), {
    net: -1,
    changed: [
      { path: "packages/envio/src/FetchState.res", net: -2 },
      { path: "packages/envio/src/Gone.res", net: -1 },
      { path: "packages/envio/src/bindings/EventStore.res", net: 2 },
    ],
  });
});

// The rules above are called directly. This runs the command a contributor and
// CI run, on a repo of its own: what it reads (untracked files, never ignored
// ones), how it groups and prints, and what it exits with.
test("the lint command on a repo with one violation of each kind, then without", () => {
  const repo = mkdtempSync(join(tmpdir(), "lint-inputs-"));
  const write = (path: string, ...lines: string[]) => {
    mkdirSync(dirname(join(repo, path)), { recursive: true });
    writeFileSync(join(repo, path), lines.join("\n"));
  };
  const lint = (env: Record<string, string | undefined>) => {
    const { status, stdout, stderr } = spawnSync(
      process.execPath,
      [join(repo, "packages/envio-tests/scripts/lint-inputs.ts")],
      { encoding: "utf8", env: { ...process.env, ...env } },
    );
    return {
      status,
      annotations: stdout.split("\n").map((line) => line.slice(0, line.lastIndexOf("::"))),
      report: stderr.split("\n").map((line) => line.split(". ")[0]),
    };
  };
  try {
    execFileSync("git", ["init", "--quiet", repo]);
    cpSync(fileURLToPath(new URL(".", import.meta.url)), join(repo, "packages/envio-tests/scripts"), {
      recursive: true,
    });
    write(".gitignore", "build/");
    write("build/Generated.res", "let cast = value => value->Utils.magic");
    const violations = [
      ["packages/envio-tests/test/Planted_test.res", "await mock.waitForHeightCall()", 'Console.log("planted")'],
      ["packages/envio/src/sources/Planted.res", "let now = Date.now()"],
      ["packages/envio/src/Cast.res", "let cast = value => value->Utils.magic"],
      ["CLAUDE.md", "See `packages/envio/src/Gone.res`."],
    ];
    violations.forEach(([path, ...lines]) => write(path, ...lines));
    const withViolations = lint({ GITHUB_ACTIONS: "true" });
    violations.forEach(([path]) => rmSync(join(repo, path)));
    const clean = lint({ GITHUB_ACTIONS: undefined });
    deepEqual(
      { withViolations, clean },
      {
        withViolations: {
          status: 1,
          annotations: [
            "::error file=packages/envio-tests/test/Planted_test.res,line=1,title=waitForHeightCall in a test",
            "::error file=packages/envio/src/sources/Planted.res,line=1,title=Date.now(...) on the real clock",
            "::error file=packages/envio/src/Cast.res,line=1,title=Utils.magic without its types",
            "::error file=packages/envio-tests/test/Planted_test.res,line=2,title=Console.log in a test",
            "::error file=CLAUDE.md,line=1,title=`packages/envio/src/Gone.res` is not a path in the repo",
            "",
          ],
          report: [
            "These tests guess at how long the indexer takes to ask the source:",
            "",
            "packages/envio-tests/test/Planted_test.res:1: waitForHeightCall in a test",
            "",
            "The runtime reads time the tests can't control:",
            "",
            "packages/envio/src/sources/Planted.res:1: Date.now(...) on the real clock",
            "",
            "This ReScript compiles, and the repo still refuses it:",
            "",
            "packages/envio/src/Cast.res:1: Utils.magic without its types",
            "packages/envio-tests/test/Planted_test.res:2: Console.log in a test",
            "",
            "The contributor docs name what isn't in the repo:",
            "",
            "CLAUDE.md:1: `packages/envio/src/Gone.res` is not a path in the repo",
            "",
          ],
        },
        clean: { status: 0, annotations: [""], report: [""] },
      },
    );
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});
