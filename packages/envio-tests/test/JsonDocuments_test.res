open Vitest

// A json field holds a document, which is as readily a string or a boolean as
// an object — alone or as an element of a list. Written inside the reorg
// threshold, so both the entity's table and its history table take it.

let scenario = Scenario.make(
  ~configYaml=`
name: json-documents
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`,
  ~schema=`
type Doc {
  id: ID!
  one: Json!
  many: [Json!]!
}
`,
)

type doc = {id: string, one: JSON.t, many: array<JSON.t>}
type docOps = {set: doc => unit}
type handlerContext = {@as("Doc") doc: docOps}

let every: array<
  JSON.t,
> = %raw(`[{"a": 1}, [1, true], 2, true, false, "s", "a \"quoted\", {braced} value"]`)

describe("Json documents of every shape", () => {
  let failure = ref(None)

  scenario->Scenario.it(
    "are stored as the documents they were, in a list as well as alone",
    ~sources=[{chain: 1}],
    ~onError=(error: ErrorHandling.t) =>
      failure :=
        Some((error.exn->Utils.prettifyExn->(Utils.magic: exn => {"message": string}))["message"]),
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(10)

      source.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 5,
            logIndex: 0,
            handler: async args => {
              let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
              every->Array.forEachWithIndex((one, index) =>
                context.doc.set({id: index->Int.toString, one, many: every})
              )
            },
          },
        ],
        ~latestFetchedBlockNumber=10,
      )
      let written = ref(false)
      indexer.getBatchWritePromise()->Promise.thenResolve(() => written := true)->ignore
      await Scenario.waitUntil(
        () => written.contents || failure.contents->Option.isSome,
        ~message="the batch to be written or refused",
        ~timeoutMs=15000.,
      )

      let {sql, pgSchema} = indexer.pg
      let stored: array<{
        "id": string,
        "one": string,
        "many": string,
      }> = await sql->Sql.query(
        `SELECT "id", "one"::text AS "one", "many"::text AS "many" FROM "${pgSchema}"."Doc" ORDER BY "id" COLLATE "C";`,
      )
      let history: array<{
        "count": string,
      }> = await sql->Sql.query(
        `SELECT count(*)::text AS "count" FROM "${pgSchema}"."envio_history_Doc";`,
      )

      let many = `{"{\\"a\\": 1}","[1, true]",2,true,false,"\\"s\\"","\\"a \\\\\\"quoted\\\\\\", {braced} value\\""}`
      t.expect((
        failure.contents,
        stored->Array.map(row => (row["id"], row["one"], row["many"])),
        history->Array.map(row => row["count"]),
      )).toEqual((
        None,
        [
          ("0", `{"a": 1}`, many),
          ("1", `[1, true]`, many),
          ("2", `2`, many),
          ("3", `true`, many),
          ("4", `false`, many),
          ("5", `"s"`, many),
          ("6", `"a \\"quoted\\", {braced} value"`, many),
        ],
        ["7"],
      ))
    },
  )
})
