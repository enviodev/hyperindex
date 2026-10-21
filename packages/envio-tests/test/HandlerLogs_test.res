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

let eventFieldNames = ["chainId", "contract", "event", "block", "logIndex", "address"]

type handlerContext = {
  log: Envio.logger,
  effect: 'input 'output. (Envio.effect<'input, 'output>, 'input) => promise<'output>,
}

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

  // Plain-JS handlers pass whatever they hold: an Error as the params, a
  // message that isn't a string, an object that refers to itself.
  Async.it("keeps what a handler passes when it isn't plain JSON", async t => {
    let error = JsError.make("boom")
    let circular = Dict.make()
    circular->Dict.set("kept", JSON.Number(1.))
    circular->Dict.set("self", circular->(Utils.magic: dict<JSON.t> => JSON.t))
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
                    context.log.error("as params", ~params=error->(Utils.magic: JsError.t => {..}))
                    context.log.info(5->(Utils.magic: int => string))
                    context.log.info(
                      "circular",
                      ~params=circular->(Utils.magic: dict<JSON.t> => {..}),
                    )
                  },
                },
              ],
              latestFetchedBlockNumber: 100,
            }),
          },
        ])
        await indexer.getBatchWritePromise()
        t.expect(
          indexer.allLogsAsJson()
          ->Array.filter(isHandlerLine)
          ->Array.map(
            line =>
              line
              ->Dict.toArray
              ->Array.filter(
                ((key, _)) =>
                  !(
                    [
                      "chainId",
                      "contract",
                      "event",
                      "block",
                      "logIndex",
                      "address",
                    ]->Array.includes(key)
                  ),
              ),
          ),
        ).toEqual([
          [
            ("level", JSON.String("uerror")),
            ("msg", JSON.String("as params")),
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
          [("level", JSON.String("uinfo")), ("msg", JSON.String("5"))],
          [
            ("level", JSON.String("uinfo")),
            ("msg", JSON.String("circular")),
            ("kept", JSON.Number(1.)),
            ("self", JSON.String("[Circular]")),
          ],
        ])
      },
    )
  })
})

describe("console in a handler", () => {
  // Formatted as Node's console would, on the level the method names, so it
  // reaches the run's log instead of writing behind the logger's back.
  Async.it("writes each console method as a line at its level", async t => {
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
                  handler: async _ => {
                    let _ = %raw(`(() => {
                      console.log("seen %d", 5, {a: 1});
                      console.info("info");
                      console.debug("debug");
                      console.warn("careful");
                      console.error("bad");
                      console.count("calls");
                      console.table([{a: 1}]);
                    })()`)
                  },
                },
              ],
              latestFetchedBlockNumber: 100,
            }),
          },
        ])
        await indexer.getBatchWritePromise()
        t.expect(
          indexer.allLogsAsJson()
          ->Array.filter(
            line =>
              switch line->Dict.get("level") {
              | Some(String("uinfo" | "udebug" | "uwarn" | "uerror")) => true
              | _ => false
              },
          )
          ->Array.map(line => (line->Dict.get("level"), line->Dict.get("msg"))),
        ).toEqual([
          (Some(JSON.String("uinfo")), Some(JSON.String("seen 5 { a: 1 }"))),
          (Some(JSON.String("uinfo")), Some(JSON.String("info"))),
          (Some(JSON.String("udebug")), Some(JSON.String("debug"))),
          (Some(JSON.String("uwarn")), Some(JSON.String("careful"))),
          (Some(JSON.String("uerror")), Some(JSON.String("bad"))),
          (Some(JSON.String("uinfo")), Some(JSON.String("calls: 1"))),
          (
            Some(JSON.String("uinfo")),
            Some(
              JSON.String(
                "┌─────────┬───┐\n│ (index) │ a │\n├─────────┼───┤\n│ 0       │ 1 │\n└─────────┴───┘",
              ),
            ),
          ),
        ])
      },
    )
  })

  // A message and one object read as `context.log`'s message and params, so
  // they print and ship as fields; anything else is formatted into the message.
  Async.it("takes a message and one object as the line's params", async t => {
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
                  handler: async _ => {
                    let log: (string, {..}) => unit = %raw(`console.log`)
                    let logError: (string, JsError.t) => unit = %raw(`console.error`)
                    let warnTwo: (string, {..}, {..}) => unit = %raw(`console.warn`)
                    let logFormatted: (string, string, {..}) => unit = %raw(`console.log`)
                    log("transfer", {"amount": 10n, "to": "0x1"})
                    logError("failed", error)
                    warnTwo("two objects", {"a": 1}, {"b": 2})
                    logFormatted("%s seen", "x", {"a": 1})
                  },
                },
              ],
              latestFetchedBlockNumber: 100,
            }),
          },
        ])
        await indexer.getBatchWritePromise()
        t.expect(
          indexer.allLogsAsJson()
          ->Array.filter(
            line =>
              switch line->Dict.get("level") {
              | Some(String("uinfo" | "uwarn" | "uerror")) => true
              | _ => false
              },
          )
          ->Array.map(
            line =>
              line
              ->Dict.toArray
              ->Array.filter(((key, _)) => !(eventFieldNames->Array.includes(key))),
          ),
        ).toEqual([
          [
            ("level", JSON.String("uinfo")),
            ("msg", JSON.String("transfer")),
            ("amount", JSON.String("10")),
            ("to", JSON.String("0x1")),
          ],
          [
            ("level", JSON.String("uerror")),
            ("msg", JSON.String("failed")),
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
          [("level", JSON.String("uwarn")), ("msg", JSON.String("two objects { a: 1 } { b: 2 }"))],
          [("level", JSON.String("uinfo")), ("msg", JSON.String("x seen { a: 1 }"))],
        ])
      },
    )
  })

  // Each line names what it's about, like `context.log` does: the event for a
  // handler or a contract register, plus the effect for an effect. A handler's
  // preload run says nothing, as its run proper says it all again; an effect
  // runs once, usually while preloading, so it's never silenced.
  Async.it("names the event, and stays silent while preloading", async t => {
    // Looked up on each call: the run routes `console` after this test's body is
    // defined.
    let log: string => unit = %raw(`message => console.log(message)`)
    let lookup = Envio.createEffect(
      {
        name: "lookup",
        input: S.string,
        output: S.string,
        rateLimit: Disable,
      },
      async ({input}) => {
        log("effect ran")
        input
      },
    )
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
                  contractRegister: async _ => log("registering"),
                  preloadHandler: async args => {
                    log("preloading")
                    let context =
                      args.context->(Utils.magic: Internal.handlerContext => handlerContext)
                    let _ = await context.effect(lookup, "in")
                  },
                  handler: async args => {
                    let context =
                      args.context->(Utils.magic: Internal.handlerContext => handlerContext)
                    let _ = await context.effect(lookup, "in")
                    log("handled")
                  },
                },
              ],
              latestFetchedBlockNumber: 100,
            }),
          },
        ])
        await indexer.getBatchWritePromise()
        let eventFields = [
          ("chainId", JSON.Number(1.)),
          ("contract", JSON.String("Token")),
          ("event", JSON.String("MockEvent")),
          ("block", JSON.Number(5.)),
          ("logIndex", JSON.Number(2.)),
          ("address", JSON.String("0x0000000000000000000000000000000000000000")),
        ]
        let line = (msg, fields) =>
          [("level", JSON.String("uinfo")), ("msg", JSON.String(msg)), ...fields]
        t.expect(
          indexer.allLogsAsJson()->Array.filter(isHandlerLine)->Array.map(Dict.toArray),
        ).toEqual([
          line("registering", eventFields),
          line("effect ran", [...eventFields, ("effect", JSON.String("lookup"))]),
          line("handled", eventFields),
        ])
      },
    )
  })
})
