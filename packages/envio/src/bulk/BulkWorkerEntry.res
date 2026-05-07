// Entry point loaded by the worker thread. Resolved at runtime via
// import.meta — see BulkMode.res for how the path is computed. The compiled
// .mjs of this file is what NodeJs.WorkerThreads.makeWorker spawns.

BulkWorker.runFromWorkerThread()->ignore
