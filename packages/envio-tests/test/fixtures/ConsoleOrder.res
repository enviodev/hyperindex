// Run by Logging.test.ts with stdout piped: a handler's `console.log` and the
// logger's lines, each larger than a pipe's buffer, written turn by turn.
switch NodeJs.Process.process.env->Dict.get("ENVIO_TEST_LOGGING_FORMAT") {
| None => JsError.throwWithMessage("ConsoleOrder.res should only be run via Logging.test.ts.")
| Some(_) => ()
}

let logger = Logger.make({strategy: "ecs-console", logFile: "", level: #info, fileLevel: #silent})
let _ = logger->Logger.routeConsole
let pad = "x"->String.repeat(200_000)
for i in 0 to 49 {
  Console.log(`console ${i->Int.toString} ${pad}`)
  logger->Logger.info(`logger ${i->Int.toString}`, ~params={"pad": pad})
}
