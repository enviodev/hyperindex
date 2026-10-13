open Vitest

// `envio dev -r` wipes the schema but keeps the effect cache: it is dumped to
// files first and uploaded into the fresh schema, so a handler re-run after the
// reset finds every output it computed before and calls no effect again.

let scenario = Scenario.make(
  ~configYaml=`
name: effect-cache-reset
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
}
`,
)

type handlerContext = {
  effect: 'input 'output. (Envio.effect<'input, 'output>, 'input) => promise<'output>,
}

let contextOf = (args: Internal.handlerArgs) =>
  args.context->(Utils.magic: Internal.handlerContext => handlerContext)

let calls = ref(0)

// Inputs and outputs a file of tab-separated lines has to escape.
let lookup = Envio.createEffect(
  {
    name: "resetLookup",
    input: S.string,
    output: S.json(~validate=false),
    rateLimit: Disable,
    cache: true,
  },
  async ({input}) => {
    calls := calls.contents + 1
    JSON.Encode.object(Dict.fromArray([("echo", JSON.Encode.string(input ++ "\t\\n"))]))
  },
)

let perChain = Envio.createEffect(
  {
    name: "resetPerChain",
    input: S.string,
    output: S.int,
    rateLimit: Disable,
    cache: true,
    crossChain: false,
  },
  async ({context}) => {
    calls := calls.contents + 1
    context.chain.id
  },
)

let inputs = ["plain", "tab\there", "line\nbreak", `back\\slash`, `"quoted"`]

let callEffects: MockSource.itemMock = {
  blockNumber: 1,
  logIndex: 0,
  handler: async args => {
    let context = args->contextOf
    for i in 0 to inputs->Array.length - 1 {
      let _ = await context.effect(lookup, inputs->Array.getUnsafe(i))
    }
    let _ = await context.effect(perChain, "chain")
  },
}

let byId = (rows: array<{"id": string, "output": JSON.t}>) =>
  rows->Array.toSorted((a, b) => String.compare(a["id"], b["id"]))

let readCaches = async (indexer: IndexerRunner.t) => (
  (await indexer.queryEffectCache(lookup, ~scope=CrossChain))->byId,
  await indexer.queryEffectCache(perChain, ~scope=Chain(1337->ChainId.fromInt)),
)

describe("A reset", () => {
  scenario->Scenario.it(
    "keeps every cached effect output, so re-indexing calls no effect again",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    async (~t, ~indexer, ~source) => {
      calls := 0
      let sourceMock = source(1337)
      await Utils.delay(0)
      await Scenario.resolveInitialHeight(~t, ~source=sourceMock, ~head=100)

      sourceMock.resolveGetItemsOrThrow([callEffects], ~latestFetchedBlockNumber=1)
      await indexer.getBatchWritePromise()
      let cached = await readCaches(indexer)
      let firstRunCalls = calls.contents

      await indexer.dumpEffectCache()
      sourceMock.setAutoHeight(100)
      let restarted = await indexer.restart(~reset=true, ())
      sourceMock.resolveGetItemsOrThrow(
        [callEffects],
        ~filter=MockSource.coveringBlock(1),
        ~latestFetchedBlockNumber=1,
      )
      await restarted.getBatchWritePromise()

      t.expect((firstRunCalls, calls.contents, await readCaches(restarted))).toEqual((6, 6, cached))
    },
  )
})
