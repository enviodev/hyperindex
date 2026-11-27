// A duration the indexer reports reads the run's clock, so a scenario controls
// it exactly: a handler that waits 5ms on virtual time accrues 0.005s, every
// run. One read off `Performance` measures the scheduler instead, and a test of
// it can only ask for "more than zero", which the metrics' millisecond rounding
// turns into a coin flip. The files below still time on `Performance`, each for
// the reason given; a new one needs a reason as good.

import type { file, violation } from "./shared.ts";
import { blankComments, isRescript, runtimeRoot } from "./shared.ts";

const performanceRead = /\bPerformance\.(?:now|secondsSince)\b/;
const realWork = "it times real I/O or CPU work, which virtual time would report as instant";
export const performanceAllowed: Record<string, string> = {
  "Clock.res": "it is the real clock",
  "Batch.res": realWork,
  "Storage.res": realWork,
  "Rollback.res": realWork,
  "PruneStaleHistory.res": realWork,
  "sources/RequestStat.res": realWork,
  "sources/EvmHyperSyncSource.res": realWork,
  "sources/SvmHyperSyncSource.res": realWork,
  "sources/FuelHyperSyncSource.res": realWork,
  "sources/RpcSource.res": realWork,
  "Supervisor.res": "it reports the process's uptime",
};

export const findPerformanceReads = (files: file[]): violation[] =>
  files
    .filter((file) => {
      if (!file.path.startsWith(runtimeRoot) || !isRescript(file)) return false;
      const module = file.path.slice(runtimeRoot.length);
      return !module.startsWith("bindings/") && !(module in performanceAllowed);
    })
    .flatMap(({ path, text }) =>
      blankComments(text).split("\n").flatMap((code, index) => {
        const match = code.match(performanceRead);
        return match
          ? [
              {
                file: path,
                line: index + 1,
                title: `${match[0]} times on the real clock`,
                fix:
                  "Time it on the run's clock (`clock->Clock.readTimeRef`, then `Clock.secondsSince`), so a scenario sets the " +
                  "duration with `indexer.delay` and `advanceTime` and asserts it exactly.",
              },
            ]
          : [];
      }),
    );
