open Vitest

// A NUL byte reaches an entity whenever a contract's bytes are read as text,
// and Postgres takes it in neither a text column nor a jsonb one. The write
// fails, the failure is recognized by the message the server gave it, and the
// batch is written again with the NULs stripped — a path that only works while
// the client reports those messages verbatim.

let scenario = Scenario.make(
  ~configYaml=`
name: nul-byte-write
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
`,
  ~schema=`
type Note {
  id: ID!
  text: String!
  tags: [String!]!
  payload: Json!
}
`,
)

let nul = String.fromCharCode(0)

type note = {id: string, text: string, tags: array<string>, payload: JSON.t}
type noteOps = {set: note => unit}
type handlerContext = {@as("Note") note: noteOps}

let contextOf = (args: Internal.handlerArgs) =>
  args.context->(Utils.magic: Internal.handlerContext => handlerContext)

describe("A NUL byte in what a handler stores", () => {
  // The indexer exits on a write it cannot make. Recording what reaches its
  // error boundary keeps a failure to recover from reading as an empty table.
  let refused = []

  scenario->Scenario.it(
    "is stripped and the row is written",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~onError=errHandler =>
      refused
      ->Array.push(
        (errHandler.exn->Utils.prettifyExn->(Utils.magic: exn => {"message": string}))["message"],
      )
      ->ignore,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Utils.delay(0)
      await Scenario.resolveInitialHeight(~t, ~source=sourceMock, ~head=100)

      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 1,
            logIndex: 0,
            handler: async args =>
              (args->contextOf).note.set({
                id: `note${nul}one`,
                text: `before${nul}after`,
                tags: [`tag${nul}one`, "plain"],
                // Buried in a document, which is where the jsonb refusal comes
                // from rather than the text one.
                payload: JSON.Encode.object(
                  Dict.fromArray([("deep", JSON.Encode.string(`in${nul}side`))]),
                ),
              }),
          },
        ],
        ~latestFetchedBlockNumber=1,
      )
      await indexer.getBatchWritePromise()

      let notes: array<note> = await indexer.query("Note")

      t.expect((refused, notes)).toEqual((
        [],
        [
          {
            id: "noteone",
            text: "beforeafter",
            tags: ["tagone", "plain"],
            payload: JSON.Encode.object(Dict.fromArray([("deep", JSON.Encode.string("inside"))])),
          },
        ],
      ))
    },
  )
})
