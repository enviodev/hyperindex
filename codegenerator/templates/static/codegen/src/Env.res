
%%private(let envSafe = EnvSafe.make())

type workerTypeSelected = RpcSelected | SkarSelected

let workerTypeSelected = switch EnvUtils.getStringEnvVar(
  ~envSafe,
  ~fallback="rpc",
  "WORKER_TYPE",
)->Js.String2.toLowerCase {
| "skar" => SkarSelected
| "rpc"
| _ =>
  RpcSelected
}

let maxEventFetchedQueueSize = EnvUtils.getIntEnvVar(~envSafe, ~fallback=500_000, "MAX_QUEUE_SIZE")
let maxProcessBatchSize = EnvUtils.getIntEnvVar(~envSafe, ~fallback=50_000, "MAX_BATCH_SIZE")
let subsquidMainnetEthArchiveServerUrl = "https://eth.archive.subsquid.io"
let skarEndpoint = EnvUtils.getStringEnvVar(
  ~envSafe,
  ~fallback=subsquidMainnetEthArchiveServerUrl,
  "SKAR_ENDPOINT",
)
