// Stands in for a forked indexer process. `FAKE_WORKER` picks how it ends, so a
// supervisor's handling of a clean finish and of a failure can both be driven
// with real processes.
const mode = process.env.FAKE_WORKER ?? "report";

// A real worker reports on a timer; the fixture reports once, as soon as it is
// started, since nothing tells it when its supervisor is listening.
process.send({
  kind: "snapshot",
  metrics: {
    workerConfig: process.env.ENVIO_INTERNAL_WORKER,
    maxConnections: process.env.ENVIO_PG_MAX_CONNECTIONS,
    bufferSize: process.env.ENVIO_INDEXING_MAX_BUFFER_SIZE,
    objectsTarget: process.env.ENVIO_IN_MEMORY_OBJECTS_TARGET,
    logFile: process.env.LOG_FILE,
    // A Date survives only under structured-clone serialization, which is
    // what a metrics snapshot's timestamps need.
    startTime: new Date(1700000000000),
    // The one reading the supervisor's barrier asks each worker for.
    hasArrivedAtHead: process.env.FAKE_WORKER_ARRIVED === "1",
  },
});

if (mode === "succeed") process.exit(0);
if (mode === "fail") process.exit(1);

// Ends the same way "succeed" does, but late enough for a supervisor to have
// taken its report and registered whatever it listens with.
if (mode === "succeed-later") setTimeout(() => process.exit(0), 60);

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
