open Vitest

// A resolver process answers a database it did not come from with silence, not
// with wrong numbers. `envio resolvers` is pointed at a database by hand, so
// nothing but this check stands between "the build is behind" and a dashboard
// reading plausible figures from columns that mean something else.

@module("node:fs") external mkdirSync: (string, {..}) => unit = "mkdirSync"
@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("node:path") @variadic external pathJoin: array<string> => string = "join"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@module("node:path") external pathDirname: string => string = "dirname"
@val external importMetaUrl: string = "import.meta.url"

type response
type getArgs = {method: string}
@val external fetchGet: (string, getArgs) => promise<response> = "fetch"
@send external json: response => promise<JSON.t> = "json"
@get external status: response => int = "status"

let probe = async url => {
  let response = await fetchGet(url, {method: "GET"})
  (response->status, await response->json)
}

let configYaml = `
name: resolver-readiness
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
}
`

let config = InternalTestIndexer.fromUserApi(~configYaml, ~schema).config

// What the indexer would have written into `envio_info` for this project.
let envioInfo =
  Core.fromUserApi(~schema, configYaml).config->JSON.parseOrThrow->Config.stripSensitiveData

let projectRoot = pathJoin([
  pathDirname(fileURLToPath(importMetaUrl)),
  ".tmp",
  "resolver-readiness",
])

let resolverSource = `
import { createResolver, S } from "envio";

export const ping = createResolver({
  name: "ping",
  output: S.string,
  timeoutMs: 5_000,
  handler: async () => "pong",
});
`

let pgSchema = TestPgSchema.make()
let sql = PgStorage.makeClient()

Async.beforeAll(async () => {
  mkdirSync(pathJoin([projectRoot, "src"]), {"recursive": true})
  writeFileSync(pathJoin([projectRoot, "src", "Resolvers.ts"]), resolverSource)

  let storage = PgStorage.makeStorageFromEnv(~config, ~sql, ~pgSchema, ~isHasuraEnabled=false)
  let persistence = PgStorage.makePersistenceFromConfig(~config, ~storage)
  await persistence->Persistence.init(
    ~chainConfigs=config.chainMap->ChainMap.values,
    ~contractMapping=config.contractMapping,
    ~envioInfo,
    ~resetCommand="envio dev -r",
    ~runCommand=Some("envio dev"),
    ~reset=true,
  )
})

Async.afterAll(async () => {
  await sql->TestPgSchema.drop(~pgSchema)
  await sql->Postgres.endSql
})

describe("resolver readiness", () => {
  Async.it("takes traffic only while the database matches the build serving it", async t => {
    let running = await ResolverProcess.serve(
      ~config,
      ~projectRoot,
      ~pgSchema,
      ~envioInfo,
      ~port=0,
    )
    let url = `http://127.0.0.1:${running.server.port->Int.toString}/readyz`

    let matching = await probe(url)

    // The indexer is redeployed with a different config underneath a resolver
    // process that keeps running: readiness has to notice, not just startup.
    let drifted = envioInfo->JSON.stringify->JSON.parseOrThrow
    switch drifted {
    | Object(dict) => dict->Dict.set("name", JSON.Encode.string("something-else"))
    | _ => ()
    }
    await sql->InternalTable.EnvioInfo.write(~pgSchema, ~envioInfo=drifted)
    let mismatched = await probe(url)

    // No `envio_info` at all is the same answer: the schema was made by a
    // version that did not record one, so nothing can be compared.
    let _ = await sql->Postgres.unsafe(`DELETE FROM "${pgSchema}"."envio_info";`)
    let uninitialised = await probe(url)

    await running.shutdown()

    let statusOf = ((status, _)) => status
    let reasonOf = ((_, body)) =>
      switch body {
      | JSON.Object(dict) =>
        switch dict->Dict.get("reason") {
        | Some(String(reason)) => reason
        | _ => "no reason"
        }
      | _ => "not an object"
      }

    t.expect((
      matching->statusOf,
      mismatched->statusOf,
      mismatched->reasonOf->String.includes("name"),
      uninitialised->statusOf,
    )).toEqual((200, 503, true, 503))
  })
})
