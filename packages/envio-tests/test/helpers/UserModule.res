// Writes user-facing TypeScript source (handlers, tests) to disk and imports it
// the way a project's own files are loaded, so fixtures exercise the real module
// boundary instead of a hand-built registration.

// Type-checks user source against a config's generated `indexer` surface.
// Lives in TypeScript (`TypeChecker.ts`) since it drives the TS compiler API.
type sources = {handlers?: string, test?: string}
@module("./TypeChecker.ts")
external checkSources: (string, sources) => array<string> = "checkSources"

@module("node:fs") external mkdirSync: (string, {..}) => unit = "mkdirSync"
@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("node:path") @variadic external pathJoin: array<string> => string = "join"
@module("node:path") external pathDirname: string => string = "dirname"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@module("node:crypto") external randomUUID: unit => string = "randomUUID"
@val external importMetaUrl: string = "import.meta.url"

// Emitted here rather than in envio so vite-node transforms the generated
// module and its bare `envio` import resolves to the instance already loaded.
let importModule: string => promise<unit> = %raw(`(path) => import(path)`)

// `file:line` of the fixture's own call — the first stack frame outside the
// helpers — so a failing suite names the fixture that produced it.
let callSite: unit => string = %raw(`() => {
  const stack = new Error().stack ?? "";
  for (const frame of stack.split("\n").slice(1)) {
    const match = frame.match(/\(?([^()\s]+):(\d+):(\d+)\)?\s*$/);
    if (!match) continue;
    const file = match[1];
    if (
      file.startsWith("node:") ||
      file.includes("InternalTestIndexer") ||
      file.includes("UserModule") ||
      file.includes("MockSource") ||
      file.includes("Scenario")
    )
      continue;
    return file.split(/[\\/]/).pop() + ":" + match[2];
  }
  return "unknown";
}`)

let tmpDir = pathJoin([pathDirname(fileURLToPath(importMetaUrl)), "..", ".tmp"])

// Kept after import: vitest renders code frames from these paths when a test
// fails, so they must outlive the run. `globalSetup.ts` clears the directory
// before any worker starts. The name is unique per call, which is also what
// makes a second import of the same source re-run its registration side
// effects instead of hitting the module cache.
let write = (~kind, ~site, ~source) => {
  mkdirSync(tmpDir, {"recursive": true})
  let slug = site->String.replaceRegExp(/[^a-zA-Z0-9]+/g, "-")
  let file = pathJoin([
    tmpDir,
    `${slug}-${kind}-${randomUUID()->String.slice(~start=0, ~end=8)}.ts`,
  ])
  writeFileSync(file, source)
  file
}

// `None` when the sources type-check, the joined errors otherwise.
let typeErrors = (~typesDts, ~handlers=?, ~test=?) =>
  switch checkSources(typesDts, {?handlers, ?test}) {
  | [] => None
  | errors => Some("Type errors:\n" ++ errors->Array.join("\n"))
  }
