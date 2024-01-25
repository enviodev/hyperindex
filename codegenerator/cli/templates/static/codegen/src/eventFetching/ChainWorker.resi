module type S = {
  type t
  let make: (
    ~caughtUpToHeadHook: t => promise<unit>=?,
    ~contractAddressMapping: ContractAddressingMap.mapping=?,
    Config.chainConfig,
  ) => t

  let stopFetchingEvents: t => promise<unit>

  let startWorker: (
    t,
    ~startBlock: int,
    ~logger: Pino.t,
    ~fetchedEventQueue: ChainEventQueue.t,
    ~checkHasReorgOccurred: (
      ReorgDetection.lastBlockScannedData,
      ~parentHash: option<string>,
      ~currentHeight: int,
    ) => unit,
  ) => promise<unit>

  let startFetchingEvents: (
    t,
    ~logger: Pino.t,
    ~fetchedEventQueue: ChainEventQueue.t,
    ~checkHasReorgOccurred: (
      ReorgDetection.lastBlockScannedData,
      ~parentHash: option<string>,
      ~currentHeight: int,
    ) => unit,
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

  let getCurrentBlockHeight: t => int
}

type chainWorker =
  | Rpc(RpcWorker.t)
  | HyperSync(HyperSyncWorker.t)
  | RawEvents(RawEventsWorker.t)

let startWorker: (
  chainWorker,
  ~startBlock: int,
  ~logger: Pino.t,
  ~fetchedEventQueue: ChainEventQueue.t,
  ~checkHasReorgOccurred: (
    ReorgDetection.lastBlockScannedData,
    ~parentHash: option<string>,
    ~currentHeight: int,
  ) => unit,
) => promise<unit>

let startFetchingEvents: (
  chainWorker,
  ~logger: Pino.t,
  ~fetchedEventQueue: ChainEventQueue.t,
  ~checkHasReorgOccurred: (
    ReorgDetection.lastBlockScannedData,
    ~parentHash: option<string>,
    ~currentHeight: int,
  ) => unit,
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

type workerSelectionWithCallback =
  | RpcSelectedWithCallback(option<RpcWorker.t => promise<unit>>)
  | HyperSyncSelectedWithCallback(option<HyperSyncWorker.t => promise<unit>>)
  | RawEventsSelectedWithCallback(option<RawEventsWorker.t => promise<unit>>)

let make: (
  ~chainConfig: Config.chainConfig,
  ~contractAddressMapping: ContractAddressingMap.mapping=?,
  workerSelectionWithCallback,
) => chainWorker

let getCurrentBlockHeight: chainWorker => int
