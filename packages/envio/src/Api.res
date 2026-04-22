// Public runtime values re-exported by the `envio` package entry point
// (`index.js`). Kept in a dedicated module so `Main` and `TestIndexer` can
// stay independent — putting these bindings in either of those modules would
// introduce a dependency cycle (TestIndexer already depends on Main for
// `Main.start`, Main depends on `Envio` for user-facing types).
//
// Generated ReScript re-binds these via `@module("envio") external` in
// `Indexer.res`; generated TypeScript re-exports them from `index.js`.

// `getGlobalIndexer()` returns an object with property getters that defer
// `Config.loadWithoutRegistrations()` until a property is actually read, so
// binding `indexer` at module load does not trigger config parsing.
let indexer: unknown = Main.getGlobalIndexer()

// Thunk form preserves the lazy-initialization contract the generated code
// used previously: callers who only import types from `envio` should never
// pay the config parse cost. `workerPath` resolves `TestIndexerWorker.res.mjs`
// as a sibling of this compiled module inside the envio package so users
// never need to configure a path.
let createTestIndexer: unit => unknown = () => {
  let workerPath =
    NodeJs.Path.join(
      NodeJs.Path.getDirname(NodeJs.ImportMeta.importMeta),
      "TestIndexerWorker.res.mjs",
    )->NodeJs.Path.toString
  TestIndexer.makeCreateTestIndexer(~config=Config.loadWithoutRegistrations(), ~workerPath)()->(
    Utils.magic: TestIndexer.t<'a> => unknown
  )
}
