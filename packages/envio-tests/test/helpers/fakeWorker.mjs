// Stands in for a forked indexer process. `FAKE_WORKER` picks how it ends, so a
// supervisor's handling of a clean finish and of a failure can both be driven
// with real processes.
const mode = process.env.FAKE_WORKER ?? "report";

process.on("message", (message) => {
  if (message.kind === "init") {
    process.send({
      kind: "snapshot",
      metrics: {
        isolatedChains: message.config.isolatedChains,
        maxConnections: process.env.ENVIO_PG_MAX_CONNECTIONS,
        logFile: process.env.LOG_FILE,
        // A Date survives only under structured-clone serialization, which is
        // what a metrics snapshot's timestamps need.
        startTime: new Date(1700000000000),
      },
    });
    if (mode === "succeed") process.exit(0);
    if (mode === "fail") process.exit(1);
  }
});

// Writes across chunk boundaries the way a real process does: a pipe hands the
// supervisor whatever has been flushed, not whole lines.
if (mode === "print") {
  process.stdout.write("first line\nsecond ");
  process.stderr.write("from stderr\n");
  process.stdout.write("line\n");
  setTimeout(() => process.exit(0), 50);
}

// Nothing else keeps a "linger" worker alive; it waits to be stopped.
if (mode === "linger") setInterval(() => {}, 1000);
