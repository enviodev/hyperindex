import type { file, violation } from "./shared.ts";
import { blankComments, testRescriptFiles } from "./shared.ts";

// Lower-case `console` too: a binding or a `%raw` that reaches it logs just the
// same, and the lint's own advice for a `%raw` is to write that binding.
const logging = /\b(?:[Cc]onsole\.[a-z]\w*|Js\.log\w*|Js\.Console\.\w+)/;

export const loggingAllowed: Record<string, string> = {
  "packages/envio-tests/test/fixtures/ConsoleOrder.res":
    "it is the program Logging.test.ts runs to check that console output and logger lines keep their order",
  "packages/envio-tests/test/HandlerLogs_test.res":
    "its handlers call console on purpose: what the indexer does with those calls is what it tests",
};

export const findLoggingInTests = (files: file[]): violation[] =>
  testRescriptFiles(files)
    .filter(({ path }) => !(path in loggingAllowed))
    .flatMap(({ path, text }) =>
      blankComments(text)
        .split("\n")
        .flatMap((code, index) => {
          const match = code.match(logging);
          return match
            ? [
                {
                  file: path,
                  line: index + 1,
                  title: `${match[0]} in a test`,
                  fix:
                    "Delete it, or assert on what it showed: nobody reads a test's output. " +
                    "A run's own log lines are in `indexer.infoAndAboveLogs()`.",
                },
              ]
            : [];
        }),
    );
