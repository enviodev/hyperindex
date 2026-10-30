open Vitest

// An effect's cache row is keyed by its input. A subgraph's contract call
// with a large argument (curve's crvusd AddMarket) has an input of several kB,
// past what a Postgres btree primary key takes, and the batch write failed:
// `index row size 2856 exceeds btree version 4 maximum 2704`.
let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: effect-cache-long-input
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

let failure: ref<option<string>> = ref(None)

// The batch is written, or the write is refused at the indexer's error boundary.
let written = async (indexer: IndexerRunner.t) => {
  let done = ref(false)
  indexer.getBatchWritePromise()->Promise.thenResolve(() => done := true)->ignore
  await Scenario.waitUntil(
    () => done.contents || failure.contents->Option.isSome,
    ~message="the batch write",
    ~timeoutMs=15000.,
  )
}

describe("An effect with a cached input of several kB", () => {
  scenario->Scenario.it(
    "is cached and read back across a restart",
    ~sources=[{chain: 1337, methods}],
    ~onError=error =>
      failure :=
        Some((error.exn->Utils.prettifyExn->(Utils.magic: exn => {"message": string}))["message"]),
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Utils.delay(0)

      let calls = ref(0)
      let longEffect = Envio.createEffect(
        {
          name: "longInputEffect",
          input: S.string,
          output: S.string,
          rateLimit: Disable,
          cache: true,
        },
        async ({input}) => {
          calls := calls.contents + 1
          `${input->String.length->Int.toString} chars`
        },
      )
      // Calldata doesn't compress the way a repeated string does, and Postgres
      // compresses an index entry before measuring it.
      let seed = ref(7)
      let longInput =
        "0x" ++
        Array.fromInitializer(~length=3000, _ => {
          seed := mod(seed.contents * 75 + 74, 65537)
          mod(seed.contents, 256)->Int.toString(~radix=16)->String.padStart(2, "0")
        })->Array.join("")

      sourceMock.resolveGetHeightOrThrow(300)
      await sourceMock.expectItemsQueries([
        {
          reply: Respond({
            items: [
              {
                blockNumber: 100,
                logIndex: 0,
                handler: async args => {
                  let context =
                    args.context->(Utils.magic: Internal.handlerContext => handlerContext)
                  let _ = await context.effect(longEffect, longInput)
                },
              },
            ],
            latestFetchedBlockNumber: 100,
          }),
        },
      ])
      await written(indexer)

      let restarted = await indexer.restart()
      await Utils.delay(0)
      let restartedSource = source(1337)
      let output = ref("")
      restartedSource.resolveGetHeightOrThrow(300)
      await restartedSource.expectItemsQueries([
        {
          reply: Respond({
            items: [
              {
                blockNumber: 101,
                logIndex: 0,
                handler: async args => {
                  let context =
                    args.context->(Utils.magic: Internal.handlerContext => handlerContext)
                  output := (await context.effect(longEffect, longInput))
                },
              },
            ],
            latestFetchedBlockNumber: 101,
          }),
        },
      ])
      if failure.contents->Option.isNone {
        await written(restarted)
      }

      t.expect((failure.contents, output.contents, calls.contents)).toEqual((None, "6002 chars", 1))
    },
  )
})
