@module("node:fs") external readFileSync: (string, string) => string = "readFileSync"
@module("node:path") @variadic external pathJoin: array<string> => string = "join"
@module("node:path") external pathDirname: string => string = "dirname"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@val external importMetaUrl: string = "import.meta.url"

// The shipped template, run as a user would get it from `envio init svm
// template -t usdc-transfers`: its own config, schema, handlers and tests.
let templateDir = pathJoin([
  pathDirname(fileURLToPath(importMetaUrl)),
  "..",
  "..",
  "cli",
  "templates",
  "static",
  "svm_usdc_transfers_template",
  "typescript",
])

let read = path => readFileSync(pathJoin([templateDir, path]), "utf8")

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=read("config.yaml"),
  ~schema=read("schema.graphql"),
  ~handlers=read("src/handlers/SplToken.ts"),
  ~test=read("src/indexer.test.ts"),
)
