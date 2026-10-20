open Vitest

// graph-node keeps its call cache when a subgraph is redeployed and synced from
// scratch: a call at a block always answers the same. `envio start -r` dropped
// the schema and every cached contract call with it, so each resync of a
// call-heavy subgraph asked a public RPC for every call again. The subgraph
// runtime's caches of block-pinned calls, balances, code and content-addressed
// files survive a reset; everything else starts over as before.
let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: subgraph-call-cache-reset
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:
  - id: 1337
    rpc:
      url: https://rpc1337.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
`,
  ~schema=`
type SimpleEntity {
  id: ID!
  value: String!
}
`,
)

type handlerContext = {
  effect: 'input 'output. (Envio.effect<'input, 'output>, 'input) => promise<'output>,
}

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

describe("A reset", () => {
  scenario->Scenario.it("keeps the cached contract calls and drops other effects' caches", ~sources=[{chain: 1337, methods}], async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let calls = ref(0)
    let others = ref(0)
    // The subgraph runtime's contract-call effect (subgraph/calls.ts).
    let callEffect = Envio.createEffect(
      {
        name: "envio_subgraph_eth_call",
        input: S.string,
        output: S.string,
        rateLimit: Disable,
        cache: true,
      },
      async ({input}) => {
        calls := calls.contents + 1
        input ++ "-answer"
      },
    )
    let otherEffect = Envio.createEffect(
      {
        name: "userEffect",
        input: S.string,
        output: S.string,
        rateLimit: Disable,
        cache: true,
      },
      async ({input}) => {
        others := others.contents + 1
        input ++ "-other"
      },
    )
    let run = async (indexer: IndexerRunner.t, ~blockNumber) => {
      let sourceMock = source(1337)
      await Utils.delay(0)
      let answers = ref(("", ""))
      sourceMock.resolveGetHeightOrThrow(300)
      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber,
            logIndex: 0,
            handler: async args => {
              let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
              answers := (
                  await context.effect(callEffect, "call@100"),
                  await context.effect(otherEffect, "x"),
                )
            },
          },
        ],
        ~latestFetchedBlockNumber=blockNumber,
      )
      await indexer.getBatchWritePromise()
      answers.contents
    }

    let first = await run(indexer, ~blockNumber=100)
    let reset = await indexer.restart(~reset=true, ())
    let second = await run(reset, ~blockNumber=100)

    t.expect((first, second, calls.contents, others.contents)).toEqual((
      ("call@100-answer", "x-other"),
      ("call@100-answer", "x-other"),
      1,
      2,
    ))
  })
})
