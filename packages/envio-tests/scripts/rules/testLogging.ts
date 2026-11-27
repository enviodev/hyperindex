import type { file, violation } from "./shared.ts";
import { testRescriptFiles, withoutLineComment } from "./shared.ts";

const logging = /\b(?:Console\.[a-z]\w*|Js\.log\w*|Js\.Console\.\w+)/;

const loggingAllowed: Record<string, string> = {
  "packages/envio-tests/test/fixtures/ConsoleOrder.res":
    "it is the program Logging.test.ts runs to check that console output and logger lines keep their order",
};

export const findLoggingInTests = (files: file[]): violation[] =>
  testRescriptFiles(files)
    .filter(({ path }) => !(path in loggingAllowed))
    .flatMap(({ path, text }) =>
      text.split("\n").flatMap((line, index) => {
        const match = withoutLineComment(line).match(logging);
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
