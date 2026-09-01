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
@get external status: response => int = "status"

type getArgs = {method: string}
@val external fetchGet: (string, getArgs) => promise<response> = "fetch"

type server
type req
type res
@module("node:http") external createServer: ((req, res) => unit) => server = "createServer"
@send external listenOnHost: (server, int, string, unit => unit) => unit = "listen"
@send external closeServer: (server, unit => unit) => unit = "close"
type address = {port: int}
@send external address: server => address = "address"
@send external setEncoding: (req, string) => unit = "setEncoding"
@send external onData: (req, @as("data") _, string => unit) => unit = "on"
@send external onEnd: (req, @as("end") _, unit => unit) => unit = "on"
@send external writeHead: (res, int, dict<string>) => unit = "writeHead"
@send external end_: (res, string) => unit = "end"
@val external processEnv: dict<string> = "process.env"
@val @scope("process") external currentPid: int = "pid"

let getStatus = async url => (await fetchGet(url, {method: "GET"}))->status

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

// What the indexer would have recorded in `envio_info` for this project.
// Passed explicitly because `serve` otherwise reads it off disk, and these
// tests run from the workspace root rather than from the fixture.
let envioInfo =
  Core.fromUserApi(~schema, configYaml).config->JSON.parseOrThrow->Config.stripSensitiveData

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
  // `envio resolvers` is spawned as a real child below, and the Rust CLI reads
  // these off disk rather than from the primed config.
  writeFileSync(pathJoin([projectRoot, "config.yaml"]), configYaml)
  writeFileSync(pathJoin([projectRoot, "schema.graphql"]), schema)
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

  Async.it("serves the declarations it just imported, and drains on shutdown", async t => {
    let running = await ResolverProcess.serve(~config, ~projectRoot, ~envioInfo, ~port=0)
    let url = `http://127.0.0.1:${running.server.port->Int.toString}/resolve`
    let body = `{"field":"ping","args":{},"selection":{},"role":"public","requestId":"r"}`

    let answer = await postJson(url, body)

    // What SIGTERM runs. Idempotent, because a rolling update can send it
    // twice, and after it the socket is gone rather than half-open.
    await running.shutdown()
    await running.shutdown()
    let afterShutdown = try {
      let _ = await postJson(url, body)
      "answered"
    } catch {
    | _ => "refused"
    }

    t.expect((answer, afterShutdown)).toEqual((%raw(`{ data: "pong" }`), "refused"))
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
    // Both halves matter: the path so the user knows which file, and a real
    // cause so they know why. A swallowed cause reads "unknown error" and
    // sends them looking in the wrong place.
    t.expect(
      caught->Option.map(message => (
        message->String.includes("src/NotThere.ts"),
        message->String.includes("Cannot find module"),
      )),
    ).toEqual(Some((true, true)))
  })

  // `envio dev` must not host the resolver server itself. Deployed, the
  // resolvers are their own service running `envio resolvers`, and dev only
  // exercises that seam -- the HTTP hop, the pool of its own, the drain -- if
  // it spawns the same command here. It is also what lets a resolver edit be a
  // restart of that process alone, with the indexer keeping its place.
  Async.it("spawns `envio resolvers` as its own process rather than serving in-process", async t => {
    processEnv->Dict.set("ENVIO_RESOLVERS_PORT", "9917")
    let dev = (await ResolverProcess.startForDev(~config, ~projectRoot))->Option.getOrThrow

    let answeredWhileRunning = await getStatus("http://127.0.0.1:9917/healthz")

    // Stopping the resolvers is what a local edit does; nothing about the
    // parent process goes with it.
    await dev.stop()
    let afterStop = try {
      let _ = await getStatus("http://127.0.0.1:9917/healthz")
      "answered"
    } catch {
    | _ => "refused"
    }

    t.expect((
      dev.pid->Option.isSome,
      dev.pid == Some(currentPid),
      answeredWhileRunning,
      afterStop,
    )).toEqual((true, false, 200, "refused"))
  })

  // Locally the resolvers have to appear in the same GraphQL endpoint as the
  // generated entity fields, or `envio dev` shows a developer everything except
  // the thing they just wrote. Hasura is a container and the resolver process
  // is on the host, so the handler it registers has to be the host's address,
  // not the one the process binds.
  Async.it("points its Hasura at the resolvers it just spawned", async t => {
    let seen: ref<array<JSON.t>> = ref([])
    let hasura = createServer((req, res) => {
      let body = ref("")
      req->setEncoding("utf8")
      req->onData(chunk => body := body.contents ++ chunk)
      req->onEnd(() => {
        let parsed = body.contents->JSON.parseOrThrow
        seen.contents->Array.push(parsed)->ignore
        let isExport = switch parsed {
        | Object(dict) =>
          switch dict->Dict.get("type") {
          | Some(String("export_metadata")) => true
          | _ => false
          }
        | _ => false
        }
        res->writeHead(200, dict{"content-type": "application/json"})
        res->end_(isExport ? `{"version":3,"sources":[]}` : `[{"message":"success"}]`)
      })
    })
    await Promise.make((resolve, _reject) =>
      hasura->listenOnHost(0, "127.0.0.1", () => resolve())
    )
    processEnv->Dict.set(
      "HASURA_GRAPHQL_ENDPOINT",
      `http://127.0.0.1:${(hasura->address).port->Int.toString}/v1/metadata`,
    )
    processEnv->Dict.set("ENVIO_RESOLVERS_PORT", "9918")

    let dev = (await ResolverProcess.startForDev(~config, ~projectRoot))->Option.getOrThrow
    // The child applies after it binds, so give it a moment past /healthz.
    let deadline = Date.now() +. 10_000.
    let rec waitForBulk = async () =>
      if seen.contents->Array.length >= 2 || Date.now() > deadline {
        ()
      } else {
        await Utils.delay(50)
        await waitForBulk()
      }
    await waitForBulk()
    await dev.stop()
    await Promise.make((resolve, _reject) => hasura->closeServer(() => resolve()))
    processEnv->Dict.set("HASURA_GRAPHQL_ENDPOINT", "")

    let handlers =
      seen.contents
      ->Array.flatMap(call =>
        switch call {
        | Object(dict) =>
          switch (dict->Dict.get("type"), dict->Dict.get("args")) {
          | (Some(String("bulk")), Some(Array(args))) =>
            args->Array.filterMap(arg =>
              switch arg {
              | Object(argDict) =>
                switch argDict->Dict.get("args") {
                | Some(Object(actionArgs)) =>
                  switch actionArgs->Dict.get("definition") {
                  | Some(Object(definition)) =>
                    switch definition->Dict.get("handler") {
                    | Some(String(handler)) => Some(handler)
                    | _ => None
                    }
                  | _ => None
                  }
                | _ => None
                }
              | _ => None
              }
            )
          | _ => []
          }
        | _ => []
        }
      )

    t.expect(handlers).toEqual([
      "http://host.docker.internal:9918/hasura-action",
      "http://host.docker.internal:9918/hasura-action",
    ])
  })
})
