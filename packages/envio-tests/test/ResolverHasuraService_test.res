open Vitest

// `envio resolvers` is the service Hasura posts to, so it is also what tells
// Hasura the fields exist. Registering its own metadata on startup is what
// keeps the schema Hasura publishes and the code answering it in one image:
// they cannot drift, because they ship together.

@module("node:fs") external mkdirSync: (string, {..}) => unit = "mkdirSync"
@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("node:path") @variadic external pathJoin: array<string> => string = "join"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@module("node:path") external pathDirname: string => string = "dirname"
@val external importMetaUrl: string = "import.meta.url"
@val external processEnv: dict<string> = "process.env"

type response
type getArgs = {method: string}
@val external fetchGet: (string, getArgs) => promise<response> = "fetch"
@get external status: response => int = "status"

let getStatus = async url => (await fetchGet(url, {method: "GET"}))->status

type server
type req
type res
@module("node:http") external createServer: ((req, res) => unit) => server = "createServer"
@send external listenOnHost: (server, int, string, unit => unit) => unit = "listen"
@send external closeServer: (server, unit => unit) => unit = "close"
type address = {port: int}
@send external address: server => address = "address"
@send external onData: (req, @as("data") _, string => unit) => unit = "on"
@send external onEnd: (req, @as("end") _, unit => unit) => unit = "on"
@send external setEncoding: (req, string) => unit = "setEncoding"
@send external writeHead: (res, int, dict<string>) => unit = "writeHead"
@send external end_: (res, string) => unit = "end"

let received: ref<array<JSON.t>> = ref([])

// How many `bulk` calls to refuse before accepting them, so a rollout where
// another replica wins the race can be reproduced.
let bulkFailures = ref(0)

// Only the two calls an apply makes: report an empty Hasura, accept the bulk.
let startFakeHasura = async () => {
  let server = createServer((req, res) => {
    let body = ref("")
    req->setEncoding("utf8")
    req->onData(chunk => body := body.contents ++ chunk)
    req->onEnd(() => {
      let parsed = body.contents->JSON.parseOrThrow
      received.contents->Array.push(parsed)->ignore
      let isExport = switch parsed {
      | Object(dict) =>
        switch dict->Dict.get("type") {
        | Some(String("export_metadata")) => true
        | _ => false
        }
      | _ => false
      }
      let (status, answer) = if isExport {
        (200, `{"version":3,"sources":[]}`)
      } else if bulkFailures.contents > 0 {
        bulkFailures := bulkFailures.contents - 1
        (400, `{"code":"already-exists","error":"action already exists"}`)
      } else {
        (200, `[{"message":"success"}]`)
      }
      res->writeHead(status, dict{"content-type": "application/json"})
      res->end_(answer)
    })
  })
  await Promise.make((resolve, _reject) =>
    server->listenOnHost(0, "127.0.0.1", () => resolve())
  )
  server
}

let callsOfType = kind =>
  received.contents->Array.filter(call =>
    switch call {
    | Object(dict) =>
      switch dict->Dict.get("type") {
      | Some(String(found)) => found === kind
      | _ => false
      }
    | _ => false
    }
  )

let configYaml = `
name: resolver-hasura-service
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
}
`

let config = InternalTestIndexer.fromUserApi(~configYaml, ~schema).config
let envioInfo =
  Core.fromUserApi(~schema, configYaml).config->JSON.parseOrThrow->Config.stripSensitiveData

let projectRoot = pathJoin([
  pathDirname(fileURLToPath(importMetaUrl)),
  ".tmp",
  "resolver-hasura-service",
])

let resolverSource = `
import { createResolver, S } from "envio";

export const ping = createResolver({
  name: "ping",
  description: "Liveness for the dashboard",
  output: S.string,
  timeoutMs: 5_000,
  handler: async () => "pong",
});
`

let publicUrl = "http://resolvers.svc:9900/hasura-action"

beforeAll(() => {
  mkdirSync(pathJoin([projectRoot, "src"]), {"recursive": true})
  writeFileSync(pathJoin([projectRoot, "src", "Resolvers.ts"]), resolverSource)
})

let clearHasuraEnv = () => {
  ["HASURA_GRAPHQL_ENDPOINT", "HASURA_GRAPHQL_ADMIN_SECRET", "ENVIO_RESOLVERS_PUBLIC_URL", "ENVIO_RESOLVERS_METADATA_INTERVAL_MS"]->Array.forEach(
    key => processEnv->Dict.set(key, ""),
  )
}

describe("envio resolvers, as Hasura's handler", () => {
  Async.it("registers its own actions on startup and keeps asserting them", async t => {
    received := []
    bulkFailures := 0
    let hasura = await startFakeHasura()
    let endpoint = `http://127.0.0.1:${(hasura->address).port->Int.toString}/v1/metadata`
    processEnv->Dict.set("HASURA_GRAPHQL_ENDPOINT", endpoint)
    processEnv->Dict.set("HASURA_GRAPHQL_ADMIN_SECRET", "testing")
    processEnv->Dict.set("ENVIO_RESOLVERS_PUBLIC_URL", publicUrl)
    processEnv->Dict.set("ENVIO_RESOLVERS_METADATA_INTERVAL_MS", "40")

    let running = await ResolverProcess.serve(~config, ~projectRoot, ~envioInfo, ~port=0)
    let appliedOnStartup = callsOfType("bulk")

    // The re-assert is a read that finds nothing to do, not a rewrite: the
    // fake reports the metadata as still empty, so it applies again.
    let exportsAfterStartup = callsOfType("export_metadata")->Array.length
    await Utils.delay(120)
    let exportsWhileRunning = callsOfType("export_metadata")->Array.length

    await running.shutdown()
    let exportsAtShutdown = callsOfType("export_metadata")->Array.length
    await Utils.delay(120)
    let exportsAfterShutdown = callsOfType("export_metadata")->Array.length
    await Promise.make((resolve, _reject) => hasura->closeServer(() => resolve()))
    clearHasuraEnv()

    t.expect((
      appliedOnStartup->Array.length,
      appliedOnStartup->Array.get(0),
      exportsWhileRunning > exportsAfterStartup,
      exportsAfterShutdown === exportsAtShutdown,
    )).toEqual((
      1,
      Some(
        %raw(`{
          type: "bulk",
          args: [
            // No set_custom_types: this project names no types of its own, and
            // an empty block is already what Hasura holds.
            {
              type: "create_action",
              args: {
                name: "ping",
                comment: "Liveness for the dashboard",
                definition: {
                  type: "query",
                  kind: "synchronous",
                  handler: "http://resolvers.svc:9900/hasura-action",
                  arguments: [],
                  output_type: "String!",
                  timeout: 5,
                },
              },
            },
            { type: "create_action_permission", args: { action: "ping", role: "public" } },
          ],
        }`),
      ),
      true,
      true,
    ))
  })

  Async.it("keeps serving when Hasura refuses the first apply, and converges", async t => {
    // Two replicas rolling out at once both find an empty Hasura and both try
    // to create the actions; the loser is told `already-exists`. That is a
    // race to converge out of, not a reason to exit -- a process that dies
    // here crash-loops through the rollout, and the metadata is already
    // correct because the other replica wrote it.
    received := []
    bulkFailures := 1
    let hasura = await startFakeHasura()
    let endpoint = `http://127.0.0.1:${(hasura->address).port->Int.toString}/v1/metadata`
    processEnv->Dict.set("HASURA_GRAPHQL_ENDPOINT", endpoint)
    processEnv->Dict.set("HASURA_GRAPHQL_ADMIN_SECRET", "testing")
    processEnv->Dict.set("ENVIO_RESOLVERS_PUBLIC_URL", publicUrl)
    processEnv->Dict.set("ENVIO_RESOLVERS_METADATA_INTERVAL_MS", "40")

    let running = await ResolverProcess.serve(~config, ~projectRoot, ~envioInfo, ~port=0)
    let servingAfterRefusal =
      await getStatus(`http://127.0.0.1:${running.server.port->Int.toString}/healthz`)

    // The loop is what converges, so it has to have been started even though
    // the first apply threw.
    await Utils.delay(140)
    let bulksSent = callsOfType("bulk")->Array.length

    await running.shutdown()
    await Promise.make((resolve, _reject) => hasura->closeServer(() => resolve()))
    clearHasuraEnv()

    t.expect((servingAfterRefusal, bulksSent > 1)).toEqual((200, true))
  })

  Async.it("serves without touching Hasura when it was not told where one is", async t => {
    received := []
    clearHasuraEnv()
    let running = await ResolverProcess.serve(~config, ~projectRoot, ~envioInfo, ~port=0)
    await running.shutdown()
    t.expect(received.contents->Array.length).toEqual(0)
  })

  Async.it("prints the metadata for anyone applying it by hand", async t => {
    // `envio resolvers metadata`: the same JSON the service would POST, so a
    // deployment that applies metadata elsewhere is not guessing at its shape.
    let metadata = await ResolverProcess.metadataJson(
      ~config,
      ~projectRoot,
      ~handlerUrl=publicUrl,
    )
    t.expect(metadata).toEqual(
      %raw(`{
        customTypes: { scalars: [], enums: [], input_objects: [], objects: [] },
        actions: [
          {
            name: "ping",
            comment: "Liveness for the dashboard",
            definition: {
              type: "query",
              kind: "synchronous",
              handler: "http://resolvers.svc:9900/hasura-action",
              arguments: [],
              output_type: "String!",
              timeout: 5,
            },
          },
        ],
        permissions: [{ action: "ping", role: "public" }],
      }`),
    )
  })
})
