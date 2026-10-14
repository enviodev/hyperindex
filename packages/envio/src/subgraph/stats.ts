/**
 * `ENVIO_SUBGRAPH_SYNC_STATS=1` counts how often the sync bridge replays a
 * mapping (§5), per phase, and prints the totals as one `SGSTATS {json}` line
 * on stderr every 30 s and at exit. A preload round that suspends is the
 * batching working; an execute round that suspends is a database round trip
 * the batch waits on, one event at a time.
 */

const enabled = process.env.ENVIO_SUBGRAPH_SYNC_STATS === "1";

type PhaseStats = { runs: number; rounds: number; maxRounds: number; byRounds: Record<string, number> };
const makePhase = (): PhaseStats => ({ runs: 0, rounds: 0, maxRounds: 0, byRounds: {} });
const stats = { preload: makePhase(), execute: makePhase() };

function record(phase: PhaseStats, rounds: number) {
  phase.runs++;
  phase.rounds += rounds;
  if (rounds > phase.maxRounds) phase.maxRounds = rounds;
  const bucket = rounds >= 5 ? "5+" : String(rounds);
  phase.byRounds[bucket] = (phase.byRounds[bucket] ?? 0) + 1;
}

if (enabled) {
  const print = () => process.stderr.write(`SGSTATS ${JSON.stringify(stats)}\n`);
  setInterval(print, 30_000).unref();
  process.on("exit", print);
}

/** `context.runSync(body)`, counting the rounds it took when stats are on. */
export async function runSyncCounted(context: any, body: () => void): Promise<void> {
  if (!enabled) return context.runSync(body);
  let rounds = 0;
  const isPreload = context.isPreload;
  try {
    await context.runSync(() => {
      rounds++;
      body();
    });
  } finally {
    record(isPreload ? stats.preload : stats.execute, rounds);
  }
}
