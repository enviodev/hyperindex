module type S = {
  module Pino: {
    type t
  }

  module ErrorHandling: {
    type t
  }

  module Address: {
    type t
  }

  module Viem: {
    type decodedEvent<'a>
  }

  module Ethers: {
    type abi
    module JsonRpcProvider: {
      type t
    }
  }

  module HyperSyncClient: {
    module Decoder: {
      type decodedEvent
    }
  }

  module ChainMap: {
    module Chain: {
      type t
      let toChainId: t => int
    }
    type t<'a>
  }

  module LogSelection: {
    type t
    type topicSelection
  }

  module Types: {
    type internalEventArgs

    module Transaction: {
      type t
    }

    module Block: {
      type t
    }

    module Log: {
      type t
    }

    type eventLog<'a> = {
      params: 'a,
      chainId: int,
      srcAddress: Address.t,
      logIndex: int,
      transaction: Transaction.t,
      block: Block.t,
    }

    module HandlerTypes: {
      module Register: {
        type t<'eventArgs>
      }
    }

    module SingleOrMultiple: {
      type t<'a>
    }

    module type Event = {
      let sighash: string
      let name: string
      let contractName: string
      type eventArgs
      let paramsRawEventSchema: RescriptSchema.S.schema<eventArgs>
      let convertHyperSyncEventArgs: HyperSyncClient.Decoder.decodedEvent => eventArgs
      let decodeHyperFuelData: string => eventArgs
      let handlerRegister: HandlerTypes.Register.t<eventArgs>
      type eventFilter
      let getTopicSelection: SingleOrMultiple.t<eventFilter> => array<LogSelection.topicSelection>
    }
    module type InternalEvent = Event with type eventArgs = internalEventArgs

    type eventBatchQueueItem = {
      timestamp: int,
      chain: ChainMap.Chain.t,
      blockNumber: int,
      logIndex: int,
      event: eventLog<internalEventArgs>,
      eventMod: module(Event with type eventArgs = internalEventArgs),
      //Default to false, if an event needs to
      //be reprocessed after it has loaded dynamic contracts
      //This gets set to true and does not try and reload events
      hasRegisteredDynamicContracts?: bool,
    }
  }

  module ContractAddressingMap: {
    type mapping
    let getAllAddresses: mapping => array<Address.t>
    let getAddressesFromContractName: (mapping, ~contractName: string) => array<Address.t>
  }

  module FetchState: {
    type id
    type eventFilters
    let applyFilters: (Types.eventBatchQueueItem, ~eventFilters: eventFilters) => bool
    type nextQuery = {
      fetchStateRegisterId: id,
      partitionId: int,
      fromBlock: int,
      toBlock: int,
      contractAddressMapping: ContractAddressingMap.mapping,
      eventFilters?: eventFilters,
    }
  }

  module ReorgDetection: {
    type blockNumberAndHash = {
      //Block hash is used for actual comparison to test for reorg
      blockHash: string,
      blockNumber: int,
    }

    type blockData = {
      ...blockNumberAndHash,
      //Timestamp is needed for multichain to action reorgs across chains from given blocks to
      //ensure ordering is kept constant
      blockTimestamp: int,
    }
  }

  module ChainWorker: {
    type reorgGuard = {
      lastBlockScannedData: ReorgDetection.blockData,
      firstBlockParentNumberAndHash: option<ReorgDetection.blockNumberAndHash>,
    }
    type blockRangeFetchArgs
    type blockRangeFetchStats
    type blockRangeFetchResponse = {
      currentBlockHeight: int,
      reorgGuard: reorgGuard,
      parsedQueueItems: array<Types.eventBatchQueueItem>,
      fromBlockQueried: int,
      heighestQueriedBlockNumber: int,
      latestFetchedBlockTimestamp: int,
      stats: blockRangeFetchStats,
      fetchStateRegisterId: FetchState.id,
      partitionId: int,
    }

    module type S = {
      let name: string
      let chain: ChainMap.Chain.t
      let getBlockHashes: (
        ~blockNumbers: array<int>,
        ~logger: Pino.t,
      ) => promise<result<array<ReorgDetection.blockData>, exn>>
      let waitForBlockGreaterThanCurrentHeight: (
        ~currentBlockHeight: int,
        ~logger: Pino.t,
      ) => promise<int>
      let fetchBlockRange: (
        ~query: blockRangeFetchArgs,
        ~logger: Pino.t,
        ~currentBlockHeight: int,
        ~setCurrentBlockHeight: int => unit,
      ) => promise<result<blockRangeFetchResponse, ErrorHandling.t>>
    }
  }

  module Config: {
    type contract = {
      name: string,
      abi: Ethers.abi,
      addresses: array<Address.t>,
      events: array<module(Types.Event)>,
      sighashes: array<string>,
    }

    type syncConfig = {
      initialBlockInterval: int,
      backoffMultiplicative: float,
      accelerationAdditive: int,
      intervalCeiling: int,
      backoffMillis: int,
      queryTimeoutMillis: int,
    }

    type hyperSyncConfig = {endpointUrl: string}

    type hyperFuelConfig = {endpointUrl: string}

    type rpcConfig = {
      provider: Ethers.JsonRpcProvider.t,
      syncConfig: syncConfig,
    }

    type syncSource = HyperSync(hyperSyncConfig) | HyperFuel(hyperFuelConfig) | Rpc(rpcConfig)

    type chainConfig = {
      syncSource: syncSource,
      startBlock: int,
      endBlock: option<int>,
      confirmedBlockThreshold: int,
      chain: ChainMap.Chain.t,
      contracts: array<contract>,
      chainWorker: module(ChainWorker.S),
    }
  }
}
