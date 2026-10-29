open Vitest

// A division by zero in a handler is a NaN or an Infinity. A float field's
// schema reads neither back, so storing one leaves an entity no later handler
// can load; the write refuses it instead. An entity with a list field is bound
// a cell at a time rather than staged (LocalWriteFailure_test), and has to
// refuse it the same way.

let scenario = Scenario.make(
  ~configYaml=`
name: non-finite-float
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
type Sample {
  id: ID!
  value: Float!
  history: [Float!]!
}
`,
)

type sample = {id: string, value: float, history: array<float>}
type handlerContext = {@as("Sample") sample: {"set": sample => unit}}

let contextOf = (args: Internal.handlerArgs) =>
  args.context->(Utils.magic: Internal.handlerContext => handlerContext)

let refusesWith = (~name, ~sample, ~reason) =>
  describe(name, () => {
    let refusal = Scenario.captureRefusal()

    scenario->Scenario.it(
      "is refused, naming the value and its column",
      ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
      ~onError=refusal.onError,
      async (~t, ~indexer, ~source) => {
        let sourceMock = source(1337)
        await Scenario.resolveInitialHeight(~source=sourceMock, ~head=100)

        await sourceMock.expectItemsQueries([
          {
            fromBlock: 1,
            toBlock: Unbounded,
            reply: Respond({
              items: [
                {
                  blockNumber: 1,
                  logIndex: 0,
                  handler: async args => (args->contextOf).sample["set"](sample),
                },
              ],
            }),
          },
        ])
        let failure = await refusal.awaitRefusalReason()

        let stored: array<unknown> = await indexer.query("Sample")

        t.expect((failure, stored)).toEqual((Some(reason), []))
      },
    )
  })

refusesWith(
  ~name="A NaN in a float field of an entity with a list field",
  ~sample={id: "1", value: Float.Constants.nan, history: []},
  ~reason="NaN is not a finite number, so it cannot be stored in the `value` column. Store a finite number, or keep it out of the entity.",
)

refusesWith(
  ~name="An Infinity in a float list",
  ~sample={id: "1", value: 1.5, history: [2.5, Float.Constants.positiveInfinity]},
  ~reason="Infinity is not a finite number, so it cannot be stored in the `history` column. Store a finite number, or keep it out of the entity.",
)
