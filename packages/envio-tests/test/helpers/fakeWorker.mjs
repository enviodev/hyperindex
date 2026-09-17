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
  // A "mute" worker takes the request and never answers, the way one that dies
  // mid-dump leaves it.
  if (message.kind === "syncCache" && mode !== "mute") {
    // Reports the dump through a snapshot before acknowledging it, so a
    // supervisor that answers early can be caught having answered before it.
    setTimeout(() => {
      process.send({ kind: "snapshot", metrics: { synced: true } });
      process.send({ kind: "cacheSynced" });
    }, 50);
  }
});

// Nothing else keeps these alive; they wait to be stopped.
if (mode === "linger" || mode === "mute") setInterval(() => {}, 1000);
