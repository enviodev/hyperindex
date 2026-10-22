// Run by Logging.test.ts: a process that logs and is then stopped by a signal,
// as a supervisor stops its workers.
switch NodeJs.Process.process.env->Dict.get("ENVIO_TEST_LOGGING_FORMAT") {
| None => JsError.throwWithMessage("SignalFlush.res should only be run via Logging.test.ts.")
| Some(_) => ()
}

let logger = Logger.make({strategy: "ecs-console", logFile: "", level: #info, fileLevel: #silent})
logger->Logger.info("before the signal")
NodeJs.Process.kill(NodeJs.Process.pid, "SIGTERM")->ignore
// Kept alive until the signal lands.
let _ = setTimeout(() => (), 10_000)
