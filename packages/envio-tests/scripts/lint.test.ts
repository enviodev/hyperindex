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
import { findListedPathsThatMoved, listedPaths } from "./rules/listedPaths.ts";
import { findUnannotatedMagic } from "./rules/magicAnnotation.ts";
import { findLogicInMigratedDirectories } from "./rules/migratedToRust.ts";
import { findGuessedWaits } from "./rules/mockSteps.ts";
import { findPerformanceReads } from "./rules/performanceReads.ts";
import { findRawFieldPaths } from "./rules/rawFieldPath.ts";
import { findUnsetDurations } from "./rules/reportedDurations.ts";
import { summarizeRescriptDirection } from "./rules/rescriptDirection.ts";
import type { file, violation } from "./rules/shared.ts";
import { blankComments } from "./rules/shared.ts";
import { findRealClockInSources } from "./rules/sourceClock.ts";
import { findLoggingInTests } from "./rules/testLogging.ts";
import { findRealTimeOnVirtualTime } from "./rules/virtualTime.ts";

// A fixture holds one line for every pattern a rule matches and one for every
// case it spares, so a rule that loses either fails here.
const fileOf = (path: string, ...lines: string[]): file => ({ path, text: lines.join("\n") });
const violationsIn =
  (file: string) =>
  (...list: [line: number, title: string, fix: string][]): violation[] =>
    list.map(([line, title, fix]) => ({ file, line, title, fix }));

test("comments are blanked and strings are read, not searched for comments", () => {
  const source = [
    'let url = "http://a//b" // gone',
    "/* outer /* inner */ still gone */ let kept = 1",
    "let quote = '\"' // gone",
    "let label = `a // kept ${value /* gone */} b`",
  ].join("\n");
  deepEqual(
    { comments: blankComments(source).split("\n"), andStrings: blankComments(source, { andStrings: true }).split("\n") },
    {
      comments: [
        'let url = "http://a//b"        ',
        "                                   let kept = 1",
        "let quote = '\"'        ",
        "let label = `a // kept ${value           } b`",
      ],
      andStrings: [
        'let url = "           "        ',
        "                                   let kept = 1",
        "let quote = '\"'        ",
        "let label = `          ${value           }  `",
      ],
    },
  );
});

test("a zero delay or a poll ahead of a mock step", () => {
  const path = "packages/envio-tests/test/Guess_test.res";
  const stepsAfterADelay = [
    "expectBlockHashLookup",
    "expectHeightCalls",
    "respondUpTo",
    "drainPendingItemsQueries",
    "resolveGetHeightOrThrow",
    "resolveInitialHeight",
    "enterReorgThreshold",
  ];
  const deleteTheDelay = (step: string) =>
    `Delete the delay: \`${step}\` waits for what it answers, or answers only what is already pending.`;
  const nameTheQueries =
    "Replace the poll with `await mock.expectItemsQueries([...])` naming the queries (`reply: LeavePending` for ones answered later).";
  const bad = [
    fileOf(
      path,
      "await Utils.delay(0)",
      "// A comment between the two hides nothing.",
      "/* Nor does a block",
      "   comment. */",
      "await mock.expectItemsQueries([])",
      "Utils.delay(0)",
      "let pending = mock.pendingItemsQueries()",
      ...stepsAfterADelay.flatMap((step) => ["await Utils.delay(0)", `await mock.${step}(1)`]),
      "while mock.pendingItemsQueries()->Array.length === 0 {",
      "  ()",
      "}",
      "await waitUntil(() =>",
      "  mock.pendingItemsQueries()->Array.length > 0",
      ")",
    ),
  ];
  const good = [
    fileOf(
      path,
      "await Utils.delay(0)",
      "let value = compute()",
      "await mock.expectItemsQueries([])",
      "// await Utils.delay(0)",
      "await mock.expectItemsQueries([])",
      "while attempts.contents < 3 {",
      "  attempts := attempts.contents + 1",
      "}",
    ),
  ];
  deepEqual(
    { bad: findGuessedWaits(bad), good: findGuessedWaits(good) },
    {
      bad: violationsIn(path)(
        [1, "Utils.delay(0) before expectItemsQueries", deleteTheDelay("expectItemsQueries")],
        [6, "Utils.delay(0) before pendingItemsQueries", deleteTheDelay("pendingItemsQueries")],
        [8, "Utils.delay(0) before expectBlockHashLookup", deleteTheDelay("expectBlockHashLookup")],
        [10, "Utils.delay(0) before expectHeightCalls", deleteTheDelay("expectHeightCalls")],
        [12, "Utils.delay(0) before respondUpTo", deleteTheDelay("respondUpTo")],
        [14, "Utils.delay(0) before drainPendingItemsQueries", deleteTheDelay("drainPendingItemsQueries")],
        [
          16,
          "Utils.delay(0) before resolveGetHeightOrThrow",
          "Delete the delay: a height answer with no call pending is held for the next call.",
        ],
        [18, "Utils.delay(0) before resolveInitialHeight", deleteTheDelay("resolveInitialHeight")],
        [20, "Utils.delay(0) before enterReorgThreshold", deleteTheDelay("enterReorgThreshold")],
        [22, "Polling pendingItemsQueries", nameTheQueries],
        [25, "Polling pendingItemsQueries", nameTheQueries],
      ),
      good: [],
    },
  );
});

test("real time in a scenario on virtual time", () => {
  const path = "packages/envio-tests/test/Timing_test.res";
  const backOnTheClock = "packages/envio-tests/test/BackOnTheClock_test.res";
  const advanceInstead = (millis: number) =>
    `Replace it with \`await indexer.advanceTime(${millis})\`: the source layer's timers only fire when the test advances the clock.`;
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
      "",
      "Scenario.run(scenario, async (~indexer, ~source) => {",
      "  await Utils.delay(7)",
      "})",
    ),
    fileOf(
      backOnTheClock,
      "// A real server answers these.",
      'let realScenario = Scenario.make(~name="real", ~virtualTime=false)',
      "",
      'realScenario->Scenario.it("one test on virtual time", ~virtualTime=true, async (~indexer, ~source) => {',
      "  await Utils.delay(5)",
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
      "Scenario.run(realScenario, async (~indexer, ~source) => {",
      "  await Utils.delay(50)",
      "})",
      "",
      'let scenario = Scenario.make(~name="virtual")',
      "",
      'scenario->Scenario.it("advances", async (~indexer, ~source) => {',
      "  await indexer.advanceTime(50)",
      "  await Utils.delay(0)",
      "  // Real time: the handler body runs off the clock.",
      "  await Utils.delay(5)",
      "  let startedAt = Date.now()",
      "  let latest = mock.getHeightOrThrowCalls->Array.length - 1",
      "})",
      "",
      'scenario->Scenario.it("off the clock", ~virtualTime=false, async (~indexer, ~source) => { // a real server',
      "  await Utils.delay(50)",
      "})",
      "",
      "// A real server answers these too.",
      "let makeRealScenario = (~name) => Scenario.make(~name, ~virtualTime=false)",
      "",
      "makeRealScenario(",
      '  ~name="made",',
      ")->Scenario.it(",
      '  "made by a function of the file\'s own",',
      "  async (~indexer, ~source) => {",
      "    await Utils.delay(50)",
      "  },",
      ")",
    ),
    fileOf(
      "packages/envio-tests/test/helpers/Scenario.res",
      "let it = (scenario, name, ~virtualTime=true, body) => runScenario(scenario, ~virtualTime, body)",
      "let onRealTime = (scenario, body) => runScenario(scenario, ~virtualTime=false, body)",
    ),
  ];
  deepEqual(
    { bad: findRealTimeOnVirtualTime(bad), good: findRealTimeOnVirtualTime(good) },
    {
      bad: [
        ...violationsIn(path)(
          [3, "~virtualTime=true is the default", "Delete it: scenarios run on virtual time unless they opt out."],
          [
            9,
            "~virtualTime=false without a reason",
            "Say on the line above why this test needs real time, such as a source talking to a real server.",
          ],
          [4, "Utils.delay(50) on virtual time", advanceInstead(50)],
          [
            5,
            "Reading the real clock on virtual time",
            "Time the scenario by how far it advanced: real time says nothing about when a virtual timer fired.",
          ],
          [
            6,
            "Counting height calls by hand on virtual time",
            "Replace the count with `await mock.expectNewHeightCalls(n)` at the step that causes the polls.",
          ],
          [
            9,
            "~sourceTiming on real time",
            "Drop `~virtualTime=false` and drive its timers with `await indexer.advanceTime(ms)`.",
          ],
          [14, "Utils.delay(7) on virtual time", advanceInstead(7)],
        ),
        ...violationsIn(backOnTheClock)([5, "Utils.delay(5) on virtual time", advanceInstead(5)]),
      ],
      good: [],
    },
  );
});

test("a test waiting for a height call it doesn't name", () => {
  const path = "packages/envio-tests/test/Height_test.res";
  const bad = [fileOf(path, "await mock.waitForHeightCall()")];
  const good = [
    fileOf("packages/envio-tests/test/helpers/Scenario.res", "await mock.waitForHeightCall()"),
    fileOf(path, "// await mock.waitForHeightCall()", "/* await mock.waitForHeightCall() */"),
  ];
  deepEqual(
    { bad: findUnnamedHeightWaits(bad), good: findUnnamedHeightWaits(good) },
    {
      bad: violationsIn(path)([
        1,
        "waitForHeightCall in a test",
        "Name the call with `await mock.expectNewHeightCalls(n)`, or answer the first height with `Scenario.resolveInitialHeight`.",
      ]),
      good: [],
    },
  );
});

test("vitest's fake timers", () => {
  const typescript = "packages/envio-tests/test/Timers.test.ts";
  const rescript = "packages/envio-tests/test/Timers_test.res";
  const fix =
    "Move time on the clock the code was given instead: `await indexer.advanceTime(ms)` for a scenario, or a `VirtualClock` passed as the module's clock for a unit test.";
  const bad = [
    fileOf(
      typescript,
      "vi.useFakeTimers();",
      "vi.advanceTimersByTime(5);",
      "vi.runAllTimers();",
      "vi.runOnlyPendingTimers();",
      "vi.runToLastTimerAsync();",
      "vi.setSystemTime(0);",
    ),
    fileOf(rescript, "Vi.useFakeTimers()"),
  ];
  const good = [
    fileOf(typescript, "// vi.useFakeTimers() is refused here.", "clock.advance(5);"),
    fileOf("packages/envio-tests/test/notes.md", "vi.useFakeTimers()"),
    fileOf("packages/envio/src/Clock.res", "Vi.useFakeTimers()"),
  ];
  deepEqual(
    { bad: findFakedTimers(bad), good: findFakedTimers(good) },
    {
      bad: [
        ...violationsIn(typescript)(
          [1, "vi.useFakeTimers fakes vitest's timers", fix],
          [2, "vi.advanceTimersByTime fakes vitest's timers", fix],
          [3, "vi.runAllTimers fakes vitest's timers", fix],
          [4, "vi.runOnlyPendingTimers fakes vitest's timers", fix],
          [5, "vi.runToLastTimerAsync fakes vitest's timers", fix],
          [6, "vi.setSystemTime fakes vitest's timers", fix],
        ),
        ...violationsIn(rescript)([1, "Vi.useFakeTimers fakes vitest's timers", fix]),
      ],
      good: [],
    },
  );
});

test("the real clock in the source layer", () => {
  const poller = "packages/envio/src/sources/Poller.res";
  const onTheClock =
    "on the clock the module was given: a virtual-time scenario only sees and moves time that goes through it.";
  const timeouts = `Use \`clock.setTimeout(~label, ...)\` and \`clock.clearTimeout\` ${onTheClock}`;
  const now = `Use \`clock.now()\` ${onTheClock}`;
  const clocked = ["LoadLayer.res", "EffectState.res", "Throttler.res"].map((name) => `packages/envio/src/${name}`);
  const bad = [
    fileOf(
      poller,
      "let timer = setTimeout(() => poll(), 1000)",
      "clearTimeout(timer)",
      "let ticker = setInterval(() => poll(), 1000)",
      "let startedAt = Date.now()",
      "let jitter = Math.random()",
      "await Utils.delay(10)",
    ),
    ...clocked.map((path) => fileOf(path, "let startedAt = Date.now()")),
  ];
  const good = [
    fileOf(
      poller,
      'let timer = clock.setTimeout(~label="poll", () => poll(), 1000)',
      "let cleared = unsetTimeout(timer)",
      "// setTimeout(() => poll(), 1000)",
    ),
    fileOf("packages/envio/src/sources/Poller.resi", "let timer = setTimeout(() => poll(), 1000)"),
    fileOf("packages/envio/src/Main.res", "let startedAt = Date.now()"),
  ];
  deepEqual(
    { bad: findRealClockInSources(bad), good: findRealClockInSources(good) },
    {
      bad: [
        ...violationsIn(poller)(
          [1, "setTimeout(...) on the real clock", timeouts],
          [2, "clearTimeout(...) on the real clock", timeouts],
          [3, "setInterval(...) on the real clock", timeouts],
          [4, "Date.now(...) on the real clock", now],
          [5, "Math.random(...) on the real clock", `Use \`clock.random()\` ${onTheClock}`],
          [6, "Utils.delay(...) on the real clock", `Use \`clock->Clock.delay(~label, millis)\` ${onTheClock}`],
        ),
        ...clocked.flatMap((path) => violationsIn(path)([1, "Date.now(...) on the real clock", now])),
      ],
      good: [],
    },
  );
});

test("a reported duration timed on Performance", () => {
  const path = "packages/envio/src/EventProcessing.res";
  const fix =
    "Time it on the run's clock (`clock->Clock.readTimeRef`, then `Clock.secondsSince`), so a scenario sets the duration with `indexer.delay` and `advanceTime` and asserts it exactly.";
  const bad = [fileOf(path, "let startedAt = Performance.now()", "let took = startedAt->Performance.secondsSince")];
  const good = [
    fileOf("packages/envio/src/Storage.res", "let startedAt = Performance.now()"),
    fileOf("packages/envio/src/sources/RpcSource.res", "let startedAt = Performance.now()"),
    fileOf("packages/envio/src/bindings/Performance.res", "let secondsSince = start => (now() -. start) /. 1000."),
    fileOf("packages/envio/src/bindings/Clock.res", "let startedAt = Performance.now()"),
    fileOf("packages/envio-tests/test/Timing_test.res", "let startedAt = Performance.now()"),
    fileOf(path, "// let startedAt = Performance.now()"),
  ];
  deepEqual(
    { bad: findPerformanceReads(bad), good: findPerformanceReads(good) },
    {
      bad: violationsIn(path)(
        [1, "Performance.now times on the real clock", fix],
        [2, "Performance.secondsSince times on the real clock", fix],
      ),
      good: [],
    },
  );
});

test("a duration nothing set", () => {
  const path = "packages/envio-tests/test/Duration_test.res";
  const waitOnTheClock = (millis: number) =>
    `Wait with \`await indexer.delay(${millis})\` and let the test pass it with \`await indexer.advanceTime(${millis})\`: the handler then takes exactly that long.`;
  const assertTheValue =
    "Assert its exact value: make the time pass with `indexer.delay` and `advanceTime`. For a metric of real work that virtual time can't set, say why on a `// Real time:` line above.";
  const bad = [
    fileOf(
      path,
      "handler: async _ => await Utils.delay(5),",
      "preloadHandler: async _ => await Utils.delay(6),",
      "contractRegister: async _ => await Utils.delay(7),",
      'Assert.ok(metric("envio_handler_seconds_total") > 0.)',
      'Assert.ok(metric("envio_preload_seconds") > 0)',
      "",
      "let stalled =",
      '  metric("envio_stall_seconds")',
      "  ->Option.getOr(0.)",
      "Assert.ok(stalled > 0.)",
    ),
  ];
  const good = [
    fileOf(
      path,
      "handler: async _ => await indexer.delay(5),",
      "handler: async _ => await Utils.delay(0),",
      "// Real time: the write goes to a real database.",
      'Assert.ok(metric("envio_storage_write_seconds_total") > 0.)',
      "",
      'Assert.ok(metric("envio_handler_seconds_total") > 0.5)',
      "",
      "let count = events->Array.length",
      "Assert.ok(count > 0)",
    ),
    fileOf("packages/envio-tests/test/helpers/SlowHandler.res", "handler: async _ => await Utils.delay(5),"),
  ];
  deepEqual(
    { bad: findUnsetDurations(bad), good: findUnsetDurations(good) },
    {
      bad: violationsIn(path)(
        [1, "A handler that takes time with Utils.delay(5)", waitOnTheClock(5)],
        [2, "A handler that takes time with Utils.delay(6)", waitOnTheClock(6)],
        [3, "A handler that takes time with Utils.delay(7)", waitOnTheClock(7)],
        [4, "A duration metric asserted as more than zero", assertTheValue],
        [5, "A duration metric asserted as more than zero", assertTheValue],
        [10, "A duration metric asserted as more than zero", assertTheValue],
      ),
      good: [],
    },
  );
});

test("Utils.magic without its types", () => {
  const path = "packages/envio/src/Cast.res";
  const title = "Utils.magic without its types";
  const fix =
    "Write both ends: `value->(Utils.magic: inputType => outputType)`. A bare cast takes whatever types inference hands it, so a change upstream changes what it casts and nothing fails.";
  const bad = [
    fileOf(
      path,
      "let params: Internal.eventParams = payload->Utils.magic",
      "let cast = Utils.magic",
      "let label = `id ${id->Utils.magic}`",
      'let url = "http://a//b" let viaUrl = b->Utils.magic',
      "let quote = '\"' let viaQuote = b->Utils.magic",
      "/* outer /* inner */ still a comment */ let afterComment = b->Utils.magic",
    ),
  ];
  const good = [
    fileOf(
      path,
      "// Utils.magic alone in a comment is not a cast.",
      'let params = payload->(Utils.magic: {"id": bigint} => Internal.eventParams)',
      "let fields = selection->(",
      "  Utils.magic: array<Internal.evmTransactionField> => array<string>",
      ")",
      'let hint = "write value->Utils.magic with its types"',
      "let source = `x->Utils.magic`",
      "/* a block comment: x->Utils.magic",
      "   /* nested */ still x->Utils.magic */",
      "let other = value->MyUtils.magic",
    ),
    fileOf("packages/cli/templates/static/greeter/src/Handlers.res", "let params = payload->Utils.magic"),
    fileOf("packages/envio/src/Cast.resi", "let cast: 'a => 'b // Utils.magic"),
  ];
  deepEqual(
    { bad: findUnannotatedMagic(bad), good: findUnannotatedMagic(good) },
    {
      bad: violationsIn(path)([1, title, fix], [2, title, fix], [3, title, fix], [4, title, fix], [5, title, fix], [6, title, fix]),
      good: [],
    },
  );
});

test("%raw naming a field path", () => {
  const path = "packages/envio-tests/test/helpers/Backend.res";
  const checkedByTheCompiler = "the compiler checks a binding's name and type, and reads nothing inside %raw.";
  const bindIt = (named: string) => `Bind it with \`@val external name: type = "${named}"\`: ${checkedByTheCompiler}`;
  const bad = [
    fileOf(
      path,
      "let backend = %raw(`process.env.ENVIO_TEST_STORAGE`)->Nullable.toOption",
      "let log: string => unit = %raw(`console.log`)",
      'let fetch = %raw("globalThis.fetch")',
      "let now = %raw(`",
      "  performance.now",
      "`)",
    ),
  ];
  const good = [
    fileOf(
      path,
      "let log: string => unit = %raw(`message => console.log(message)`)",
      "let empty = %raw(`null`)",
      "let half = %raw(`0.5`)",
      "let keys = %raw(`Object.keys(value)`)",
      "// let backend = %raw(`process.env.ENVIO_TEST_STORAGE`)",
    ),
    fileOf("packages/cli/templates/static/greeter/src/Handlers.res", "let log = %raw(`console.log`)"),
  ];
  deepEqual(
    { bad: findRawFieldPaths(bad), good: findRawFieldPaths(good) },
    {
      bad: violationsIn(path)(
        [
          1,
          "%raw reading process.env.ENVIO_TEST_STORAGE",
          `Read it with \`NodeJs.Process.process.env->Dict.get("ENVIO_TEST_STORAGE")\`: ${checkedByTheCompiler}`,
        ],
        [2, "%raw reading console.log", bindIt("console.log")],
        [3, "%raw reading globalThis.fetch", bindIt("globalThis.fetch")],
        [4, "%raw reading performance.now", bindIt("performance.now")],
      ),
      good: [],
    },
  );
});

test("logging in a test", () => {
  const path = "packages/envio-tests/test/Noisy_test.res";
  const fix =
    "Delete it, or assert on what it showed: nobody reads a test's output. A run's own log lines are in `indexer.infoAndAboveLogs()`.";
  const bad = [
    fileOf(
      path,
      "Console.log(result)",
      'Js.log2("result", result)',
      "Js.Console.log(result)",
      '@val external say: string => unit = "console.log"',
      "let warn = %raw(`message => console.warn(message)`)",
    ),
  ];
  const good = [
    fileOf("packages/envio-tests/test/fixtures/ConsoleOrder.res", 'Console.log("a line")'),
    fileOf("packages/envio-tests/test/HandlerLogs_test.res", '@val external log: string => unit = "console.log"'),
    fileOf("packages/envio/src/Logger.res", "Console.log(line)"),
    fileOf(
      "packages/envio-tests/test/Quiet_test.res",
      "// Console.log(result)",
      "/* console.log(result) */",
      "TestConsole.lines()",
      "let consoleLines = []",
    ),
  ];
  deepEqual(
    { bad: findLoggingInTests(bad), good: findLoggingInTests(good) },
    {
      bad: violationsIn(path)(
        [1, "Console.log in a test", fix],
        [2, "Js.log2 in a test", fix],
        [3, "Js.Console.log in a test", fix],
        [4, "console.log in a test", fix],
        [5, "console.warn in a test", fix],
      ),
      good: [],
    },
  );
});

test("a doc naming a path that isn't there", () => {
  const skill = ".claude/skills/testing/SKILL.md";
  const fix =
    "Name where it lives now, or drop the sentence if it is gone. A path the build generates takes a placeholder, as in `<project>/.envio/types.d.ts`, and a word that is no path at all loses its backticks.";
  const missing = (line: number, word: string): [number, string, string] => [
    line,
    `\`${word}\` is not a path in the repo`,
    fix,
  ];
  const tracked = [
    fileOf("rust-toolchain.toml", ""),
    fileOf("packages/cli/src/lib.rs", ""),
    fileOf("packages/cli/src/config_parsing/human_config.rs", ""),
    fileOf("packages/envio-tests/test/HandlerLogs_test.res", ""),
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
      "- The cast is at `packages/gone/Gone.res:7`.",
      "```bash",
      "pnpm vitest run test/Gone_test.res.mjs   # see packages/gone/notes.md, then (packages/gone/more.md)",
      "```",
      "~~~",
      "cat packages/gone/tilde.md",
      "~~~",
    ),
    fileOf(skill, "See `test/helpers/Gone.res`."),
  ];
  const good = [
    ...tracked,
    fileOf(
      "CLAUDE.md",
      "- Rust CLI: `packages/cli`, entry `src/lib.rs`, parsing in `src/config_parsing/`, pinned by `rust-toolchain.toml`.",
      "- Scenario projects: `scenarios/` (`test_codegen`).",
      "- Never edit `<project>/.envio/`; logs land in `.test-logs/*.jsonl`.",
      "- `pnpm`, not `npm`. Read `.res` modules. See `Scenario.it` and `packages/cli/src/lib.rs:12`.",
      "- Run `cd packages/cli && cargo test --lib config_parsing`, or `pnpm vitest run test/HandlerLogs_test.res.mjs`.",
      "- Prose naming packages/nowhere is not checked, nor is `../outside/the-repo` or `@types/node`.",
      "",
      "```bash",
      "(cd scenarios/test_codegen && pnpm test)   # config.yaml, then ./packages/cli",
      "```",
    ),
    fileOf("README.md", "Not a contributor doc: `packages/nowhere/Gone.res`."),
  ];
  deepEqual(
    { bad: findMissingDocPaths(bad), good: findMissingDocPaths(good) },
    {
      bad: [
        ...violationsIn("CLAUDE.md")(
          missing(1, "packages/envio/src/Prometheus.res"),
          missing(2, "system_config.rs"),
          missing(3, "test/Missing_test.res"),
          missing(4, "templates/"),
          missing(5, "packages/gone/Gone.res:7"),
          missing(7, "test/Gone_test.res.mjs"),
          missing(7, "packages/gone/notes.md,"),
          missing(7, "(packages/gone/more.md)"),
          missing(10, "packages/gone/tilde.md"),
        ),
        ...violationsIn(skill)(missing(1, "test/helpers/Gone.res")),
      ],
      good: [],
    },
  );
});

test("a path a rule lists that is no longer in the repo", () => {
  const renamed = [
    "packages/envio/src/LoadLayer.res",
    "packages/envio/src/Clock.res",
    "packages/envio-tests/test/fixtures/ConsoleOrder.res",
  ];
  const everyListedFile = listedPaths.map(({ path }) => fileOf(path, ""));
  const fix = "Rename the entry along with the file, or drop it if the file is gone.";
  deepEqual(
    {
      bad: findListedPathsThatMoved(everyListedFile.filter(({ path }) => !renamed.includes(path))),
      good: findListedPathsThatMoved(everyListedFile),
    },
    {
      bad: [
        ...violationsIn("packages/envio-tests/scripts/rules/sourceClock.ts")([
          1,
          "`packages/envio/src/LoadLayer.res` is listed here and is not in the repo",
          fix,
        ]),
        ...violationsIn("packages/envio-tests/scripts/rules/performanceReads.ts")([
          1,
          "`packages/envio/src/Clock.res` is listed here and is not in the repo",
          fix,
        ]),
        ...violationsIn("packages/envio-tests/scripts/rules/testLogging.ts")([
          1,
          "`packages/envio-tests/test/fixtures/ConsoleOrder.res` is listed here and is not in the repo",
          fix,
        ]),
      ],
      good: [],
    },
  );
});

test("ReScript logic in a directory that moved to Rust", () => {
  const migrated = ["packages/envio/src/sources"];
  const logic = fileOf(
    "packages/envio/src/sources/SourceManager.res",
    "// The word external in a comment binds nothing.",
    "let pickSource = sources => sources->Array.get(0)",
  );
  const binding = fileOf(
    "packages/envio/src/sources/ChainBuffer.res",
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
test("the lint command on a repo with one violation of every rule, then without", () => {
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
    listedPaths.forEach(({ path }) => write(path, ""));
    write("build/Generated.res", "let cast = value => value->Utils.magic");
    const renamed = "packages/envio/src/Throttler.res";
    const violations = [
      [
        "packages/envio-tests/test/Planted_test.res",
        "await Utils.delay(0)",
        "await mock.expectItemsQueries([])",
        "await mock.waitForHeightCall()",
        "handler: async _ => await Utils.delay(5),",
        'Console.log("planted")',
        'scenario->Scenario.it("planted", ~virtualTime=true, body)',
      ],
      ["packages/envio-tests/test/Planted.test.ts", "vi.useFakeTimers();"],
      ["packages/envio/src/sources/Planted.res", "let now = Date.now()"],
      ["packages/envio/src/Timed.res", "let startedAt = Performance.now()"],
      ["packages/envio/src/Cast.res", "let cast = value => value->Utils.magic", "let home = %raw(`process.env.HOME`)"],
      ["CLAUDE.md", "See `packages/envio/src/Gone.res`."],
    ];
    violations.forEach(([path, ...lines]) => write(path, ...lines));
    rmSync(join(repo, renamed));
    const withViolations = lint({ GITHUB_ACTIONS: "true" });
    violations.forEach(([path]) => rmSync(join(repo, path)));
    write(renamed, "");
    const clean = lint({ GITHUB_ACTIONS: undefined });
    deepEqual(
      { withViolations, clean },
      {
        withViolations: {
          status: 1,
          annotations: [
            "::error file=packages/envio-tests/test/Planted_test.res,line=1,title=Utils.delay(0) before expectItemsQueries",
            "::error file=packages/envio-tests/test/Planted_test.res,line=6,title=~virtualTime=true is the default",
            "::error file=packages/envio-tests/test/Planted_test.res,line=3,title=waitForHeightCall in a test",
            "::error file=packages/envio-tests/test/Planted.test.ts,line=1,title=vi.useFakeTimers fakes vitest's timers",
            "::error file=packages/envio-tests/test/Planted_test.res,line=4,title=A handler that takes time with Utils.delay(5)",
            "::error file=packages/envio/src/sources/Planted.res,line=1,title=Date.now(...) on the real clock",
            "::error file=packages/envio/src/Timed.res,line=1,title=Performance.now times on the real clock",
            "::error file=packages/envio/src/Cast.res,line=1,title=Utils.magic without its types",
            "::error file=packages/envio/src/Cast.res,line=2,title=%25raw reading process.env.HOME",
            "::error file=packages/envio-tests/test/Planted_test.res,line=5,title=Console.log in a test",
            "::error file=CLAUDE.md,line=1,title=`packages/envio/src/Gone.res` is not a path in the repo",
            "::error file=packages/envio-tests/scripts/rules/sourceClock.ts,line=1,title=`packages/envio/src/Throttler.res` is listed here and is not in the repo",
            "",
          ],
          report: [
            "These tests guess at how long the indexer takes to ask the source:",
            "",
            "packages/envio-tests/test/Planted_test.res:1: Utils.delay(0) before expectItemsQueries",
            "packages/envio-tests/test/Planted_test.res:6: ~virtualTime=true is the default",
            "packages/envio-tests/test/Planted_test.res:3: waitForHeightCall in a test",
            "packages/envio-tests/test/Planted.test.ts:1: vi.useFakeTimers fakes vitest's timers",
            "packages/envio-tests/test/Planted_test.res:4: A handler that takes time with Utils.delay(5)",
            "",
            "The runtime reads time the tests can't control:",
            "",
            "packages/envio/src/sources/Planted.res:1: Date.now(...) on the real clock",
            "packages/envio/src/Timed.res:1: Performance.now times on the real clock",
            "",
            "This ReScript compiles, and the repo still refuses it:",
            "",
            "packages/envio/src/Cast.res:1: Utils.magic without its types",
            "packages/envio/src/Cast.res:2: %raw reading process.env.HOME",
            "packages/envio-tests/test/Planted_test.res:5: Console.log in a test",
            "",
            "These name a path that isn't in the repo:",
            "",
            "CLAUDE.md:1: `packages/envio/src/Gone.res` is not a path in the repo",
            "packages/envio-tests/scripts/rules/sourceClock.ts:1: `packages/envio/src/Throttler.res` is listed here and is not in the repo",
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
