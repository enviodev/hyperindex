open Vitest

// A logger that captures its own NDJSON output, so two of them can be compared
// for cross-talk.
let makeCaptureLogger = () => {
  let lines = []
  let logger = Pino.MultiStreamLogger.makeWithMultiStream(
    {
      customLevels: Logging.logLevels,
      level: #trace,
      base: %raw("{}"),
      timestamp: false,
    },
    Pino.MultiStreamLogger.multistream([
      {
        stream: {write: line => lines->Array.push(line)->ignore},
        level: #trace,
      },
    ]),
  )
  (logger, lines)
}

let parse = lines => lines->Array.map(line => line->JSON.parseOrThrow)

describe("Per-indexer logger scope", () => {
  it("routes each indexer's logs to its own logger only", t => {
    let (loggerA, linesA) = makeCaptureLogger()
    let (loggerB, linesB) = makeCaptureLogger()

    loggerA->Logging.info({"msg": "from A", "chainId": 1})
    loggerB->Logging.info({"msg": "from B", "chainId": 137})

    t.expect((linesA->parse, linesB->parse)).toEqual((
      [%raw(`{level: 30, msg: "from A", chainId: 1}`)],
      [%raw(`{level: 30, msg: "from B", chainId: 137}`)],
    ))
  })

  it("silencing one indexer's logger leaves the other untouched", t => {
    let (loggerA, linesA) = makeCaptureLogger()
    let (loggerB, linesB) = makeCaptureLogger()

    loggerA->Logging.setLogLevel(#silent)
    loggerA->Logging.info({"msg": "muted"})
    loggerB->Logging.info({"msg": "still logged"})

    t.expect((linesA->parse, linesB->parse, loggerB->Pino.getLevel)).toEqual((
      [],
      [%raw(`{level: 30, msg: "still logged"}`)],
      #trace,
    ))
  })

  it("writes context params on every line instead of binding a child", t => {
    let (logger, lines) = makeCaptureLogger()
    let params = {"chainId": 1, "partitionId": "0"}->Internal.toLogParams

    logger->Logging.trace(params->Logging.withParams({"msg": "first", "fromBlock": 10}))
    logger->Logging.warn(params->Logging.withParams({"msg": "second", "fromBlock": 20}))

    t.expect(lines->parse).toEqual([
      %raw(`{level: 10, chainId: 1, partitionId: "0", msg: "first", fromBlock: 10}`),
      %raw(`{level: 40, chainId: 1, partitionId: "0", msg: "second", fromBlock: 20}`),
    ])
  })

  it("merges item params into user logs, with user params winning", t => {
    let (logger, lines) = makeCaptureLogger()
    let userLogger =
      logger->Logging.userLogger(
        ~params={"contract": "ERC20", "event": "Transfer", "chainId": 1}->Internal.toLogParams,
      )

    userLogger.info("hello", ~params={"custom": true})
    userLogger.warn("overridden", ~params={"chainId": 137})

    t.expect(lines->parse).toEqual([
      %raw(`{level: 34, contract: "ERC20", event: "Transfer", chainId: 1, custom: true, msg: "hello"}`),
      %raw(`{level: 36, contract: "ERC20", event: "Transfer", chainId: 137, msg: "overridden"}`),
    ])
  })

  it("keeps ErrorHandling params on the logged error", t => {
    let (logger, lines) = makeCaptureLogger()

    Utils.Error.make("boom")
    ->ErrorHandling.make(~logger, ~msg="Failed", ~params={"entityName": "User"})
    ->ErrorHandling.log

    let withoutStack = %raw(`(lines) => lines.map(({err: {stack, ...err}, ...line}) => ({...line, err}))`)

    t.expect(lines->parse->withoutStack).toEqual([
      %raw(`{level: 50, entityName: "User", msg: "Failed", err: {type: "Error", message: "boom"}}`),
    ])
  })

  it("builds a silent instance logger without touching the process logger", t => {
    let processLevel = Logger.root->Pino.getLevel
    let silent = Logger.make(~userLogLevel=#silent)

    t.expect((silent->Pino.getLevel, Logger.root->Pino.getLevel)).toEqual((#silent, processLevel))
  })

  it("reuses one quiet logger instance across calls", t => {
    t.expect(Logger.quiet() === Logger.quiet()).toBe(true)
  })
})
