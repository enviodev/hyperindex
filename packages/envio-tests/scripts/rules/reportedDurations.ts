import type { file, violation } from "./shared.ts";
import { isRealTimeAt, isTestHelper, testRescriptFiles, withoutLineComment } from "./shared.ts";

export const findUnsetDurations = (files: file[]): violation[] =>
  testRescriptFiles(files)
    .filter(({ path }) => !isTestHelper(path))
    .flatMap(({ path, text }) => {
      const lines = text.split("\n");
      return lines.flatMap((line, index) => {
        const found: violation[] = [];
        const code = withoutLineComment(line);
        // A real wait as a handler's whole body is there to take time, and the time
        // a handler takes is measured on the run's clock: on virtual time it adds
        // nothing, on real time it adds whatever the scheduler gives, which can
        // round to zero. A `// Real time:` comment doesn't change that.
        const handlerDelay = code.match(
          /\b(?:preloadHandler|handler|contractRegister)\s*:\s*async\b.*\bUtils\.delay\((?!0\))([^)]*)\)/,
        );
        if (handlerDelay) {
          found.push({
            file: path,
            line: index + 1,
            title: `A handler that takes time with Utils.delay(${handlerDelay[1]})`,
            fix:
              `Wait with \`await indexer.delay(${handlerDelay[1]})\` and let the test pass it with ` +
              `\`await indexer.advanceTime(${handlerDelay[1]})\`: the handler then takes exactly that long.`,
          });
        }
        // A duration only has to be more than zero when nothing set it, and a metric
        // exported to the millisecond reads zero whenever the scheduler was quick.
        const statement = lines.slice(Math.max(0, index - 2), index + 1).join("\n");
        if (
          />\s*0\.?(?![\d.])/.test(code) &&
          /_seconds(?:_total)?"/.test(statement) &&
          !isRealTimeAt(lines, index)
        ) {
          found.push({
            file: path,
            line: index + 1,
            title: "A duration metric asserted as more than zero",
            fix:
              "Assert its exact value: make the time pass with `indexer.delay` and `advanceTime`. " +
              "For a metric of real work that virtual time can't set, say why on a `// Real time:` line above.",
          });
        }
        return found;
      });
    });
