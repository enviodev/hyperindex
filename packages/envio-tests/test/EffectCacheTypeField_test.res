open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: effect-cache-type-field
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

type output = {
  @as("type") type_: string,
  value: string,
}

let calls = ref(0)

let typed = Envio.createEffect(
  {
    name: "typedOutput",
    input: S.string,
    output: S.schema(s => {
      type_: s.matches(S.string),
      value: s.matches(S.string),
    }),
    rateLimit: Disable,
    cache: true,
  },
  async ({input}) => {
    calls := calls.contents + 1
    {type_: "token", value: input}
  },
)

let outputs = ref([])

let callEffect: MockSource.itemMock = {
  blockNumber: 1,
  logIndex: 0,
  handler: async args => {
    let context = args->contextOf
    outputs := [await context.effect(typed, "a"), await context.effect(typed, "b")]
  },
}

// https://github.com/enviodev/hyperindex/issues/674
describe("An effect output with a type field", () => {
  scenario->Scenario.it(
    "is cached and served from the cache after a restart",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    async (~t, ~indexer, ~source) => {
      calls := 0
      let sourceMock = source(1337)
      await Scenario.resolveInitialHeight(~source=sourceMock, ~head=100)

      await sourceMock.expectItemsQueries([
        {fromBlock: 1, toBlock: Unbounded, reply: Respond({items: [callEffect]})},
      ])
      await indexer.getBatchWritePromise()
      let cached = await indexer.queryEffectCache(typed, ~scope=CrossChain)

      await indexer.dumpEffectCache()
      sourceMock.setAutoHeight(100)
      let restarted = await indexer.restart(~reset=true, ())
      await sourceMock.expectItemsQueries([
        {coversBlock: 1, reply: Respond({items: [callEffect], latestFetchedBlockNumber: 1})},
      ])
      await restarted.getBatchWritePromise()

      t.expect((
        cached->Array.toSorted((a, b) => String.compare(a["id"], b["id"])),
        calls.contents,
        outputs.contents,
      )).toEqual((
        [
          {"id": `"a"`, "output": %raw(`{type: "token", value: "a"}`)},
          {"id": `"b"`, "output": %raw(`{type: "token", value: "b"}`)},
        ],
        2,
        [{type_: "token", value: "a"}, {type_: "token", value: "b"}],
      ))
    },
  )
})
