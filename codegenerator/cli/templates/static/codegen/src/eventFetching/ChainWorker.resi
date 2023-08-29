type chainId = int
type exn += UndefinedChainConfig(chainId)

module type S = {
  type t
  let make: (~caughtUpToHeadHook: t => promise<unit>=?, Config.chainConfig) => t

  let stopFetchingEvents: t => promise<unit>
  let startFetchingEvents: (
    t,
    ~logger: Pino.t,
    ~fetchedEventQueue: ChainEventQueue.t,
  ) => promise<unit>
  let addNewRangeQueriedCallback: t => promise<unit>
  let getLatestFetchedBlockTimestamp: t => int
  let addDynamicContractAndFetchMissingEvents: (
    t,
    ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
    ~fromBlock: int,
    ~fromLogIndex: int,
    ~logger: Pino.t,
  ) => promise<array<Types.eventBatchQueueItem>>
}

module RpcWorker: S
module SkarWorker: S
module EthArchiveWorker: S
module RawEventsWorker: S

type chainWorker =
  | Rpc(RpcWorker.t)
  | Skar(SkarWorker.t)
  | EthArchive(EthArchiveWorker.t)
  | RawEvents(RawEventsWorker.t)

let startFetchingEvents: (
  chainWorker,
  ~logger: Pino.t,
  ~fetchedEventQueue: ChainEventQueue.t,
) => promise<unit>
let addNewRangeQueriedCallback: chainWorker => promise<unit>
let getLatestFetchedBlockTimestamp: chainWorker => int
let addDynamicContractAndFetchMissingEvents: (
  chainWorker,
  ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
  ~fromBlock: int,
  ~fromLogIndex: int,
  ~logger: Pino.t,
) => promise<array<Types.eventBatchQueueItem>>
let make: (Env.workerTypeSelected, ~chainConfig: Config.chainConfig) => chainWorker

