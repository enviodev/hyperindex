open Vitest

// A custom resolver squatting a name envio-serve generates from schema.graphql
// makes the schema ambiguous. Serve refuses to start on it, but by then the
// user is reading a deployment log; the build is where they can act.
//
// Its own file because registration is process-global: a module declaring a
// colliding name would follow every other test in the file that imported it.

@module("node:fs") external mkdirSync: (string, {..}) => unit = "mkdirSync"
@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("node:path") @variadic external pathJoin: array<string> => string = "join"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@module("node:path") external pathDirname: string => string = "dirname"
@val external importMetaUrl: string = "import.meta.url"

let projectRoot = pathJoin([
  pathDirname(fileURLToPath(importMetaUrl)),
  ".tmp",
  "resolver-collisions",
])

let configYaml = `
name: resolver-collisions
resolvers: src/Resolvers.ts
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
enum Direction {
  Long
  Short
}

type Position {
  id: ID!
  account: String! @index
  direction: Direction!
}
`

let config = InternalTestIndexer.fromUserApi(~schema, ~configYaml).config

// `Position_aggregate` is the aggregate root field serve derives from the
// `Position` entity, and `Direction` is the schema's own enum.
let resolverSource = `
import { createResolver, defineType, S } from "envio";

export const squatting = createResolver({
  name: "Position_aggregate",
  output: S.array(defineType("Direction", { id: S.string })),
  timeoutMs: 5_000,
  handler: async () => [],
});
`

beforeAll(() => {
  mkdirSync(pathJoin([projectRoot, "src"]), {"recursive": true})
  writeFileSync(pathJoin([projectRoot, "src", "Resolvers.ts"]), resolverSource)
})

describe("resolver name collisions", () => {
  Async.it("fails the build naming every generated name a declaration squats", async t => {
    let caught = try {
      await ResolverProcess.writeManifest(~config, ~projectRoot)
      None
    } catch {
    | JsExn(e) => e->JsExn.message
    | _ => None
    }
    t.expect(caught).toEqual(
      Some(
        "Custom resolvers collide with names envio-serve generates from schema.graphql:\n" ++
        "  - resolver 'Position_aggregate' is the aggregate field of entity 'Position'\n" ++
        "  - type 'Direction' is an enum declared in schema.graphql\n" ++ "Rename them: envio-serve owns those names and refuses to start on an ambiguous schema.",
      ),
    )
  })
})
