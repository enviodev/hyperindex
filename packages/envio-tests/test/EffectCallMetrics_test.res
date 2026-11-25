open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: effect-call-metrics
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`,
)

type handlerContext = {
  effect: 'input 'output. (Envio.effect<'input, 'output>, 'input) => promise<'output>,
}

describe("effect call metrics", () => {
  Async.it("time an effect call by the run's clock", async t => {
    await scenario->Scenario.run(
      ~sources=[{chain: 1}],
      async (~indexer, ~source) => {
        let slowEffect = Envio.createEffect(
          {name: "slowEffect", input: S.string, output: S.string, rateLimit: Disable},
          async ({input}) => {
            await indexer.delay(5)
            input
          },
        )
        let mock = source(1)
        mock.resolveGetHeightOrThrow(300)
        await mock.expectItemsQueries([
          {
            reply: Respond({
              items: [
                {
                  blockNumber: 5,
                  logIndex: 1,
                  handler: async args => {
                    let context =
                      args.context->(Utils.magic: Internal.handlerContext => handlerContext)
                    let _ = await context.effect(slowEffect, "input")
                  },
                },
              ],
              latestFetchedBlockNumber: 100,
            }),
          },
        ])
        await indexer.advanceTime(5)
        await indexer.getBatchWritePromise()
        let valueOf = async name =>
          switch await indexer.metric(name) {
          | [{value}] => value
          | samples => `${samples->Array.length->Int.toString} samples`
          }
        t.expect({
          "calls": await valueOf("envio_effect_call_total"),
          "seconds": await valueOf("envio_effect_call_seconds"),
          "secondsTotal": await valueOf("envio_effect_call_seconds_total"),
        }).toEqual({"calls": "1", "seconds": "0.005", "secondsTotal": "0.005"})
      },
    )
  })
})
