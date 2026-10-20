open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: handler-logs
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

type handlerContext = {log: Envio.logger}

let isHandlerLine = (line: dict<JSON.t>) =>
  switch line->Dict.get("level") {
  | Some(String("uinfo" | "uerror")) => true
  | _ => false
  }

describe("context.log", () => {
  // A handler's line carries the event it's about, with the handler's own
  // params on top: one named like an event field replaces it in place.
  Async.it("writes the event's fields with the handler's params over them", async t => {
    let error = JsError.make("boom")
    await scenario->Scenario.run(
      ~sources=[{chain: 1}],
      async (~indexer, ~source) => {
        let mock = source(1)
        mock.resolveGetHeightOrThrow(300)
        await mock.expectItemsQueries([
          {
            reply: Respond({
              items: [
                {
                  blockNumber: 5,
                  logIndex: 2,
                  handler: async args => {
                    let context =
                      args.context->(Utils.magic: Internal.handlerContext => handlerContext)
                    context.log.info("transfer seen", ~params={"block": 6, "amount": 10n})
                    context.log.errorWithExn(
                      "transfer failed",
                      error->(Utils.magic: JsError.t => exn),
                    )
                  },
                },
              ],
              latestFetchedBlockNumber: 100,
            }),
          },
        ])
        await indexer.getBatchWritePromise()
        let eventFields = (~block) => [
          ("chainId", JSON.Number(1.)),
          ("contract", JSON.String("Token")),
          ("event", JSON.String("MockEvent")),
          ("block", JSON.Number(block)),
          ("logIndex", JSON.Number(2.)),
          ("address", JSON.String("0x0000000000000000000000000000000000000000")),
        ]
        t.expect(
          indexer.allLogsAsJson()->Array.filter(isHandlerLine)->Array.map(Dict.toArray),
        ).toEqual([
          [
            ("level", JSON.String("uinfo")),
            ("msg", JSON.String("transfer seen")),
            ...eventFields(~block=6.),
            ("amount", JSON.String("10")),
          ],
          [
            ("level", JSON.String("uerror")),
            ("msg", JSON.String("transfer failed")),
            ...eventFields(~block=5.),
            (
              "err",
              JSON.Object(
                dict{
                  "type": JSON.String("Error"),
                  "message": JSON.String("boom"),
                  "stack": JSON.String(error->JsError.stack->Option.getOr("")),
                },
              ),
            ),
          ],
        ])
      },
    )
  })
})
