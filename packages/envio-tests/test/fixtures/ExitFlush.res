// Run by Logging.test.ts: a process that logs and then ends the way
// `ENVIO_TEST_EXIT` names, before the lines it logged were handed over.
switch NodeJs.Process.process.env->Dict.get("ENVIO_TEST_LOGGING_FORMAT") {
| None => JsError.throwWithMessage("ExitFlush.res should only be run via Logging.test.ts.")
| Some(_) => ()
}

@val @scope("process") external exitWith: int => unit = "exit"

let keepAlive = () => {
  let _ = setTimeout(() => (), 10_000)
}

let logger = Logger.make({strategy: "ecs-console", logFile: "", level: #info, fileLevel: #silent})
logger->Logger.info("before")
switch NodeJs.Process.process.env->Dict.get("ENVIO_TEST_EXIT") {
| Some("signal") =>
  NodeJs.Process.kill(NodeJs.Process.pid, "SIGTERM")->ignore
  keepAlive()
| Some("handled signal") =>
  NodeJs.Process.onSignal("SIGINT", () => {
    logger->Logger.info("handled")
    exitWith(0)
  })
  NodeJs.Process.kill(NodeJs.Process.pid, "SIGINT")->ignore
  keepAlive()
| Some("exit") => exitWith(3)
| Some("long line") =>
  logger->Logger.info("x"->String.repeat(3_000_000))
  logger->Logger.info("after")
| _ => JsError.throwWithMessage("Set ENVIO_TEST_EXIT.")
}
