// A test names the height calls it causes; only a helper waits for one without
// accounting for it, the way answering the first height does.

import type { file, violation } from "./shared.ts";
import { isTestHelper, testRescriptFiles, withoutLineComment } from "./shared.ts";

export const findUnnamedHeightWaits = (files: file[]): violation[] =>
  testRescriptFiles(files)
    .filter(({ path }) => !isTestHelper(path))
    .flatMap(({ path, text }) =>
      text.split("\n").flatMap((line, index) =>
        /\.waitForHeightCall\(/.test(withoutLineComment(line))
          ? [
              {
                file: path,
                line: index + 1,
                title: "waitForHeightCall in a test",
                fix: "Name the call with `await mock.expectNewHeightCalls(n)`, or answer the first height with `Scenario.resolveInitialHeight`.",
              },
            ]
          : [],
      ),
    );
