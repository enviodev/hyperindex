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

let makeTmpPath: unit => string = %raw(`() =>
  require("path").join(require("os").tmpdir(), "envio-logger-close-" + process.hrtime.bigint() + ".log")`)
let readFile: string => string = %raw(`(path) => require("fs").readFileSync(path, "utf8")`)

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

  Async.it("flushes and releases a file-backed logger on close", async t => {
    let logFilePath = makeTmpPath()
    let logger = Logging.makeLogger(
      ~logStrategy=Logging.FileOnly,
      ~logFilePath,
      ~defaultFileLogLevel=#trace,
      ~userLogLevel=#trace,
    )
    logger->Logging.info({"msg": "written before close"})

    // Resolving proves the transport was ended; the file proves it flushed.
    await logger->Logging.close

    t.expect(readFile(logFilePath)->String.includes(`"written before close"`)).toBe(true)
  })

  // `both-prettyconsole` nests a file destination inside a multistream, which
  // has to be closed through its members — the multistream itself throws on
  // `end` because its console member is write-only.
  Async.it("flushes the file nested in a console+file multistream", async t => {
    let logFilePath = makeTmpPath()
    let logger = Logging.makeLogger(
      ~logStrategy=Logging.Both,
      ~logFilePath,
      ~defaultFileLogLevel=#trace,
      ~userLogLevel=#trace,
    )
    logger->Logging.error({"msg": "nested destination line"})

    await logger->Logging.close

    t.expect(readFile(logFilePath)->String.includes(`"nested destination line"`)).toBe(true)
  })

  // A console multistream has no closable resource and throws on `end`, so
  // closing one must be a no-op rather than a rejected promise.
  Async.it("closes a console logger without throwing", async t => {
    let logger = Env.makeLogger(~userLogLevel=#silent)

    let closed = try {
      await logger->Logging.close
      true
    } catch {
    | _ => false
    }

    t.expect(closed).toBe(true)
  })

  it("builds a silent instance logger without touching the process logger", t => {
    let processLevel = Env.logger->Pino.getLevel
    let silent = Env.makeLogger(~userLogLevel=#silent)

    t.expect((silent->Pino.getLevel, Env.logger->Pino.getLevel)).toEqual((#silent, processLevel))
  })
})
