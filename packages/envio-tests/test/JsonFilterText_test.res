open Vitest

// A document is written with its NUL characters left out and its lone
// surrogates replaced (NulByteWrite_test). A getWhere by a document holding
// either has to be spelled the same way, or jsonb refuses it and fails the
// handler. The document as the handler wrote it is not the one stored, so it
// matches nothing; the one stored is found.

let scenario = Scenario.make(
  ~configYaml=`
name: json-filter-text
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Doc {
  id: ID!
  payload: Json!
}
`,
  ~unsupported=[
    {
      backend: #clickhouseOnly,
      reason: "ClickHouse stores the NUL character Postgres leaves out, so the document stored is the one written",
    },
  ],
)

type doc = {id: string, payload: JSON.t}
type docOps = {
  set: doc => unit,
  getWhere: dict<dict<JSON.t>> => promise<array<doc>>,
}
type handlerContext = {@as("Doc") doc: docOps}

let inHandler = (~block, run: handlerContext => promise<unit>): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args =>
    await args.context->(Utils.magic: Internal.handlerContext => handlerContext)->run,
}

let payload: JSON.t = %raw(`{"nul": "x\u0000y", "lone": "\uD800"}`)
let stored: JSON.t = %raw(`{"nul": "xy", "lone": "�"}`)

describe("A getWhere by a document holding text Postgres can't", () => {
  let refused = []

  scenario->Scenario.it(
    "answers rather than failing the handler",
    ~sources=[{chain: 1}],
    ~onError=errHandler =>
      refused
      ->Array.push(
        (errHandler.exn->Utils.prettifyExn->(Utils.magic: exn => {"message": string}))["message"],
      )
      ->ignore,
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      await Scenario.resolveInitialHeight(~source, ~head=100)

      await source.expectItemsQueries([
        {
          coversBlock: 1,
          reply: Respond({
            items: [inHandler(~block=1, async context => context.doc.set({id: "1", payload}))],
            latestFetchedBlockNumber: 1,
          }),
        },
      ])
      await indexer.getBatchWritePromise()

      // Restarted, so the getWhere is answered by Postgres rather than memory.
      source.setAutoHeight(100)
      let indexer = await indexer.restart()
      let found = []
      await source.expectItemsQueries([
        {
          coversBlock: 2,
          reply: Respond({
            items: [
              inHandler(~block=2, async context =>
                for at in 0 to 1 {
                  let filter = [payload, stored]->Array.getUnsafe(at)
                  let ids =
                    (await context.doc.getWhere(dict{"payload": dict{"_eq": filter}}))->Array.map(
                      doc => doc.id,
                    )
                  found->Array.push(ids)->ignore
                }
              ),
            ],
            latestFetchedBlockNumber: 2,
          }),
        },
      ])
      let written = ref(false)
      indexer.getBatchWritePromise()->Promise.thenResolve(() => written := true)->ignore
      await Scenario.waitUntil(
        () => written.contents || refused->Array.length > 0,
        ~message="the getWhere to answer or be refused",
        ~timeoutMs=15000.,
      )

      t.expect((refused, found)).toEqual(([], [[], ["1"]]))
    },
  )
})
