// Worker entry point for the test indexer. Spawned by
// `TestIndexer.makeCreateTestIndexer` as a sibling of `Api.res.mjs`;
// `import.meta.url` on this file resolves inside the envio package so the
// worker does not need to be copied into each generated project.

TestIndexer.initTestWorker()
