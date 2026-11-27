// The source layer's time is whatever its clock says, so a scenario on virtual
// time sees every timer it arms. One armed on the real clock fires on its own
// schedule, between a test's steps, with nothing in the test to say so.

import type { file, violation } from "./shared.ts";
import { isRescript, runtimeRoot, withoutLineComment } from "./shared.ts";

// `Performance.now()` stays: it measures how long real work took, for request
// stats, and a virtual clock would report every request as instant.
const realTime = [
  {
    pattern: /(?<![.\w])(?:setTimeout|clearTimeout|setInterval)\(/,
    use: "`clock.setTimeout(~label, ...)` and `clock.clearTimeout`",
  },
  { pattern: /\bUtils\.delay\(/, use: "`clock->Clock.delay(~label, millis)`" },
  { pattern: /\bDate\.now\(/, use: "`clock.now()`" },
  { pattern: /\bMath\.random\(/, use: "`clock.random()`" },
];

// The run-wide timers outside the sources take the same clock.
const clockedModules = ["LoadLayer.res", "EffectState.res", "Throttler.res"].map((name) => `${runtimeRoot}${name}`);

export const findRealClockInSources = (files: file[]): violation[] =>
  files
    .filter(
      (file) =>
        (file.path.startsWith(`${runtimeRoot}sources/`) && isRescript(file)) || clockedModules.includes(file.path),
    )
    .flatMap(({ path, text }) =>
      text.split("\n").flatMap((line, index) => {
        const code = withoutLineComment(line);
        return realTime.flatMap(({ pattern, use }) =>
          pattern.test(code)
            ? [
                {
                  file: path,
                  line: index + 1,
                  title: `${code.match(pattern)?.[0]}...) on the real clock`,
                  fix: `Use ${use} on the clock the module was given: a virtual-time scenario only sees and moves time that goes through it.`,
                },
              ]
            : [],
        );
      }),
    );
