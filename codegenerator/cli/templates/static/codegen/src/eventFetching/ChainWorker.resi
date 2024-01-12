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
  ) => promise<unit>

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

module SkarWorker: S

type chainWorker =
  | Rpc(RpcWorker.t)
  | Skar(SkarWorker.t)
  | RawEvents(RawEventsWorker.t)

let startWorker: (
  chainWorker,
  ~startBlock: int,
  ~logger: Pino.t,
  ~fetchedEventQueue: ChainEventQueue.t,
) => promise<unit>

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

type workerSelectionWithCallback =
  | RpcSelectedWithCallback(option<RpcWorker.t => promise<unit>>)
  | SkarSelectedWithCallback(option<SkarWorker.t => promise<unit>>)
  | RawEventsSelectedWithCallback(option<RawEventsWorker.t => promise<unit>>)

let make: (
  ~chainConfig: Config.chainConfig,
  ~contractAddressMapping: ContractAddressingMap.mapping=?,
  workerSelectionWithCallback,
) => chainWorker
