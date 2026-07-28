// Build a logger from the process environment. Instances are independent:
// setting the level on one can't affect another.
//
// There is deliberately no shared process-logger export. `Bin` builds the one
// process logger and passes it to the command it runs, so reaching a
// console-level logger takes an explicit `make()` rather than picking up an
// ambient value. Anything running in-process alongside tests wants `quiet`.
let make: (~userLogLevel: Pino.logLevel=?) => Pino.t

// Shared silent logger for the in-process indexer instances nothing disposes
// (test indexers and mocks). Built on first use and reused, since pino exposes
// no way to release a logger's stream. Silent unless LOG_LEVEL is set.
let quiet: unit => Pino.t
