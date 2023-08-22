// TODO: move to `eventFetching` folder
type chainId = int
type exn += UndefinedChainConfig(chainId)

module type ChainWorker = {
  type t
  let make: Config.chainConfig => t
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

module SkarWorker: ChainWorker
module RawEventsWorker: ChainWorker
module RpcWorker: ChainWorker
module EthArchiveWorker: ChainWorker

type chainWorker = Rpc(RpcWorker.t) | Skar(SkarWorker.t) | EthArchive(EthArchiveWorker.t) | RawEvents(RawEventsWorker.t)

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
