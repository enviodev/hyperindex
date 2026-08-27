open Vitest

// What `envio resolvers` does once Rust hands over: find the module named by
// `resolvers:` in config.yaml, import it so its declarations register, and
// then either write the artefacts the image carries or serve them.

@module("node:fs") external mkdirSync: (string, {..}) => unit = "mkdirSync"
@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("node:fs") external readFileSync: (string, string) => string = "readFileSync"
@module("node:path") @variadic external pathJoin: array<string> => string = "join"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@module("node:path") external pathDirname: string => string = "dirname"
@val external importMetaUrl: string = "import.meta.url"

type response
type fetchArgs = {method: string, headers: dict<string>, body: string}
@val external fetch: (string, fetchArgs) => promise<response> = "fetch"
@send external json: response => promise<JSON.t> = "json"

let postJson = async (url, body) => {
  let response = await fetch(
    url,
    {method: "POST", headers: dict{"content-type": "application/json"}, body},
  )
  await response->json
}

// Inside envio-tests rather than the system temp dir: the module under test
// imports "envio" by name, which only resolves from within the workspace.
let projectRoot = pathJoin([
  pathDirname(fileURLToPath(importMetaUrl)),
  ".tmp",
  "resolver-process",
])

let resolverSource = `
import { createResolver, defineType, S } from "envio";

export const positions = createResolver({
  name: "positions",
  description: "Open positions for an account",
  args: { account: S.string },
  output: S.array(
    defineType("PositionSummary", { id: S.string, sizeInUsd: S.bigint })
  ),
  timeoutMs: 30_000,
  handler: async ({ args, db }) => {
    const rows = await db.find("Position", {
      where: { account: { _eq: args.account } },
    });
    return rows.map((row) => ({ id: row.id, sizeInUsd: row.sizeInUsd }));
  },
});

export const ping = createResolver({
  name: "ping",
  output: S.string,
  timeoutMs: 5_000,
  handler: async () => "pong",
});
`

let configYaml = `
name: resolver-process
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
type Position {
  id: ID!
  account: String! @index
  sizeInUsd: BigInt!
  isLong: Boolean!
}
`

let config = InternalTestIndexer.fromUserApi(~schema, ~configYaml).config

// The same project with nothing declared, for the artefacts codegen has to
// emit either way.
let configWithoutResolvers =
  InternalTestIndexer.fromUserApi(
    ~schema,
    ~configYaml=configYaml->String.replace("resolvers: src/Resolvers.ts\n", ""),
  ).config

beforeAll(() => {
  mkdirSync(pathJoin([projectRoot, "src"]), {"recursive": true})
  writeFileSync(pathJoin([projectRoot, "src", "Resolvers.ts"]), resolverSource)
})

describe("envio resolvers", () => {
  Async.it("writes the manifest and the SDL the image carries", async t => {
    await ResolverProcess.writeManifest(~config, ~projectRoot)

    let manifest =
      readFileSync(pathJoin([projectRoot, ".envio", "resolvers.json"]), "utf8")->JSON.parseOrThrow
    let sdl = readFileSync(pathJoin([projectRoot, ".envio", "resolvers.graphql"]), "utf8")

    t.expect((manifest, sdl)).toEqual((
      %raw(`{
        schemaVersion: 1,
        resolvers: [
          {
            name: "positions",
            description: "Open positions for an account",
            args: [{ name: "account", type: "String!" }],
            type: "[PositionSummary!]!",
            admin: false,
            cacheTtlMs: 0,
            timeoutMs: 30000,
          },
          {
            name: "ping",
            args: [],
            type: "String!",
            admin: false,
            cacheTtlMs: 0,
            timeoutMs: 5000,
          },
        ],
        types: [
          { kind: "scalar", name: "BigInt" },
          {
            kind: "object",
            name: "PositionSummary",
            fields: [
              { name: "id", type: "String!" },
              { name: "sizeInUsd", type: "BigInt!" },
            ],
          },
        ],
      }`),
      `scalar BigInt

type PositionSummary {
  id: String!
  sizeInUsd: BigInt!
}

extend type Query {
  positions(account: String!): [PositionSummary!]!
  ping: String!
}
`,
    ))
  })

  Async.it("emits empty artefacts when the project declares none", async t => {
    let root = pathJoin([projectRoot, "empty"])
    await ResolverProcess.writeManifest(~config=configWithoutResolvers, ~projectRoot=root)

    let manifest =
      readFileSync(pathJoin([root, ".envio", "resolvers.json"]), "utf8")->JSON.parseOrThrow
    let sdl = readFileSync(pathJoin([root, ".envio", "resolvers.graphql"]), "utf8")

    // Written rather than skipped, so nothing downstream needs a
    // "file missing" branch — and parseable by serve, which registers no
    // custom fields from it rather than failing to start.
    t.expect((manifest, sdl)).toEqual((
      %raw(`{ schemaVersion: 1, resolvers: [], types: [] }`),
      "",
    ))
  })

  Async.it("serves the declarations it just imported", async t => {
    let {server, pool} = await ResolverProcess.serve(~config, ~projectRoot, ~port=0)
    let answer = await postJson(
      `http://127.0.0.1:${server.port->Int.toString}/resolve`,
      `{"field":"ping","args":{},"selection":{},"role":"public","requestId":"r"}`,
    )
    await server.close()
    await pool->ResolverProcess.endPool
    t.expect(answer).toEqual(%raw(`{ data: "pong" }`))
  })

  Async.it("says which file it couldn't load rather than starting empty", async t => {
    let broken = InternalTestIndexer.fromUserApi(
      ~schema,
      ~configYaml=configYaml->String.replace("src/Resolvers.ts", "src/NotThere.ts"),
    ).config
    let caught = try {
      await ResolverProcess.writeManifest(~config=broken, ~projectRoot)
      None
    } catch {
    | JsExn(e) => e->JsExn.message
    | _ => None
    }
    t.expect(
      caught->Option.map(message => message->String.includes("src/NotThere.ts")),
    ).toEqual(Some(true))
  })
})
