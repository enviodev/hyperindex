// A test names the height calls it causes; only a helper waits for one without
// accounting for it, the way answering the first height does.

import type { file, violation } from "./shared.ts";
import { blankComments, isTestHelper, testRescriptFiles } from "./shared.ts";

export const findUnnamedHeightWaits = (files: file[]): violation[] =>
  testRescriptFiles(files)
    .filter(({ path }) => !isTestHelper(path))
    .flatMap(({ path, text }) =>
      blankComments(text)
        .split("\n")
        .flatMap((code, index) =>
          /\.waitForHeightCall\(/.test(code)
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
