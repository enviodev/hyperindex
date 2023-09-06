%%private(let envSafe = EnvSafe.make())

type workerTypeSelected = RpcSelected | SkarSelected | EthArchiveSelected | RawEventsSelected

let workerTypeSelected = switch EnvUtils.getStringEnvVar(
  ~envSafe,
  ~fallback="rpc",
  "WORKER_TYPE",
)->Js.String2.toLowerCase {
| "raw_events" => RawEventsSelected
| "skar" => SkarSelected
| "etharchive"
| "eth-archive" =>
  EthArchiveSelected
| "rpc"
| _ =>
  RpcSelected
}

let maxEventFetchedQueueSize = EnvUtils.getIntEnvVar(~envSafe, ~fallback=100_000, "MAX_QUEUE_SIZE")
let maxProcessBatchSize = EnvUtils.getIntEnvVar(~envSafe, ~fallback=10_000, "MAX_BATCH_SIZE")
