module type S = {
  module Viem: {
    type decodedEvent<'a>
  }

  module Ethers: {
    type ethAddress
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

  module Enums: {
    module EventType: {
      type t
    }
  }

  module Types: {
    type eventName = Enums.EventType.t
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
      srcAddress: Ethers.ethAddress,
      logIndex: int,
      transaction: Transaction.t,
      block: Block.t,
    }

    module type Event = {
      let key: string
      let name: string
      let contractName: string
      let eventName: Enums.EventType.t
      type eventArgs
      let eventArgsSchema: RescriptSchema.S.schema<eventArgs>
      let convertHyperSyncEventArgs: HyperSyncClient.Decoder.decodedEvent => eventArgs
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
    let getAllAddresses: mapping => array<Ethers.ethAddress>
    let getAddressesFromContractName: (mapping, ~contractName: string) => array<Ethers.ethAddress>
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

  module Config: {
    type contract = {
      name: string,
      abi: Ethers.abi,
      addresses: array<Ethers.ethAddress>,
      events: array<module(Types.Event)>,
    }

    type syncConfig = {
      initialBlockInterval: int,
      backoffMultiplicative: float,
      accelerationAdditive: int,
      intervalCeiling: int,
      backoffMillis: int,
      queryTimeoutMillis: int,
    }

    type hyperSyncConfig = {
      endpointUrl: string,
    }

    type hyperFuelConfig = {
      endpointUrl: string,
    }

    type rpcConfig = {
      provider: Ethers.JsonRpcProvider.t,
      syncConfig: syncConfig,
    }

    /**
    A generic type where for different values of HyperSync and Rpc.
    Where first param 'a represents the value for hypersync and the second
    param 'b for rpc
    */
    type source<'hyperSync, 'hyperFuel, 'rpc> = HyperSync('hyperSync) | HyperFuel('hyperFuel) | Rpc('rpc)

    type syncSource = source<hyperSyncConfig, hyperFuelConfig, rpcConfig>

    type chainConfig = {
      syncSource: syncSource,
      startBlock: int,
      endBlock: option<int>,
      confirmedBlockThreshold: int,
      chain: ChainMap.Chain.t,
      contracts: array<contract>,
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

  module ChainWorkerTypes: {
    type reorgGuard = {
      lastBlockScannedData: ReorgDetection.blockData,
      firstBlockParentNumberAndHash: option<ReorgDetection.blockNumberAndHash>,
    }
    type blockRangeFetchStats
    type blockRangeFetchResponse<'a, 'b, 'c> = {
      currentBlockHeight: int,
      reorgGuard: reorgGuard,
      parsedQueueItems: array<Types.eventBatchQueueItem>,
      fromBlockQueried: int,
      heighestQueriedBlockNumber: int,
      latestFetchedBlockTimestamp: int,
      stats: blockRangeFetchStats,
      fetchStateRegisterId: FetchState.id,
      partitionId: int,
      worker: Config.source<'a, 'b, 'c>,
    }
  }
}
