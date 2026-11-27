// Faked timers replace the global setTimeout that Clock.real arms, so a test
// that fakes them freezes the real-time parts of a run (startup, writes, the
// mock's own deadlines) while leaving the virtual clock where it was.

import type { file, violation } from "./shared.ts";
import { testRoot, withoutLineComment } from "./shared.ts";

const fakeTimers =
  /\b[vV]i\.(?:useFakeTimers|advanceTimers\w*|runAllTimers\w*|runOnlyPendingTimers\w*|runToLastTimer\w*|setSystemTime)\b/;

export const findFakedTimers = (files: file[]): violation[] =>
  files
    .filter(({ path }) => path.startsWith(testRoot) && /\.(?:res|ts)$/.test(path))
    .flatMap(({ path, text }) =>
      text.split("\n").flatMap((line, index) => {
        const match = withoutLineComment(line).match(fakeTimers);
        return match
          ? [
              {
                file: path,
                line: index + 1,
                title: `${match[0]} fakes vitest's timers`,
                fix:
                  "Move time on the clock the code was given instead: `await indexer.advanceTime(ms)` " +
                  "for a scenario, or a `VirtualClock` passed as the module's clock for a unit test.",
              },
            ]
          : [];
      }),
    );
