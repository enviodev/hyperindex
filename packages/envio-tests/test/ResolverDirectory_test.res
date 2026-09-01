open Vitest

// `resolvers:` may name a directory, not just a file. A project may keep its
// resolvers as `resolvers/<name>/index.ts` — a parent directory of
// subdirectories — and `handlers:` already auto-loads that way, so the two
// config fields should behave the same.

@module("node:fs") external mkdirSync: (string, {..}) => unit = "mkdirSync"
@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("node:fs") external readFileSync: (string, string) => string = "readFileSync"
@module("node:path") @variadic external pathJoin: array<string> => string = "join"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@module("node:path") external pathDirname: string => string = "dirname"
@val external importMetaUrl: string = "import.meta.url"

let projectRoot = pathJoin([
  pathDirname(fileURLToPath(importMetaUrl)),
  ".tmp",
  "resolver-directory",
])

let resolverFile = (name, output) => `
import { createResolver, S } from "envio";

export const ${name} = createResolver({
  name: "${name}",
  output: ${output},
  timeoutMs: 5_000,
  handler: async () => ${output === "S.string" ? `"${name}"` : "1"},
});
`

let configYaml = `
name: resolver-directory
resolvers: src/resolvers
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`

let schema = `
type Position {
  id: ID!
  account: String! @index
}
`

let config = InternalTestIndexer.fromUserApi(~schema, ~configYaml).config

beforeAll(() => {
  mkdirSync(pathJoin([projectRoot, "src", "resolvers", "nested"]), {"recursive": true})
  writeFileSync(
    pathJoin([projectRoot, "src", "resolvers", "top.ts"]),
    resolverFile("atTheTop", "S.string"),
  )
  writeFileSync(
    pathJoin([projectRoot, "src", "resolvers", "nested", "index.ts"]),
    resolverFile("inASubdirectory", "S.string"),
  )
  // Sits beside the resolvers in the reference layout. Importing it would run
  // `describe` outside a test runner, so skipping it is what makes the
  // directory form usable on a project that keeps its specs next to the code.
  writeFileSync(
    pathJoin([projectRoot, "src", "resolvers", "nested", "index.spec.ts"]),
    `describe("not a resolver module", () => {});\n`,
  )
  // A helper the resolvers might import: no declarations, must not break the walk.
  writeFileSync(
    pathJoin([projectRoot, "src", "resolvers", "helpers.ts"]),
    `export const unused = 1;\n`,
  )
})

describe("resolvers: pointing at a directory", () => {
  Async.it("registers every resolver in the tree, and skips spec files", async t => {
    await ResolverProcess.writeManifest(~config, ~projectRoot)

    let manifest =
      readFileSync(pathJoin([projectRoot, ".envio", "resolvers.json"]), "utf8")->JSON.parseOrThrow
    let names = switch manifest {
    | Object(d) =>
      switch d->Dict.get("resolvers") {
      | Some(Array(items)) =>
        items->Array.map(item =>
          switch item {
          | Object(r) =>
            switch r->Dict.get("name") {
            | Some(String(n)) => n
            | _ => "?"
            }
          | _ => "?"
          }
        )
      | _ => []
      }
    | _ => []
    }

    // Order is the sorted file path -- `nested/index.ts` before `top.ts` --
    // not declaration order, because with a directory there is no single
    // declaration order to preserve. Pinned because it decides the field order
    // in the emitted SDL, and that should not depend on the filesystem.
    t.expect(names).toEqual(["inASubdirectory", "atTheTop"])
  })
})
