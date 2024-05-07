module type S = {
  module Ethers: {
    type ethAddress
    type abi
    module JsonRpcProvider: {
      type t
    }
  }

  module ChainMap: {
    module Chain: {
      type t
      let toChainId: t => int
    }
    type t<'a>
  }

  module Types: {
    type eventName
    type event
    type eventLog<'a> = {
      params: 'a,
      chainId: int,
      txOrigin: option<Ethers.ethAddress>,
      blockNumber: int,
      blockTimestamp: int,
      blockHash: string,
      srcAddress: Ethers.ethAddress,
      transactionHash: string,
      transactionIndex: int,
      logIndex: int,
    }

    type eventBatchQueueItem = {
      timestamp: int,
      chain: ChainMap.Chain.t,
      blockNumber: int,
      logIndex: int,
      event: event,
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
      events: array<Types.eventName>,
    }

    type syncConfig = {
      initialBlockInterval: int,
      backoffMultiplicative: float,
      accelerationAdditive: int,
      intervalCeiling: int,
      backoffMillis: int,
      queryTimeoutMillis: int,
    }

    type serverUrl = string

    type rpcConfig = {
      provider: Ethers.JsonRpcProvider.t,
      syncConfig: syncConfig,
    }

    /**
A generic type where for different values of HyperSync and Rpc.
Where first param 'a represents the value for hypersync and the second
param 'b for rpc
*/
    type source<'a, 'b> = HyperSync('a) | Rpc('b)

    type syncSource = source<serverUrl, rpcConfig>

    type chainConfig = {
      syncSource: syncSource,
      startBlock: int,
      endBlock: option<int>,
      confirmedBlockThreshold: int,
      chain: ChainMap.Chain.t,
      contracts: array<contract>,
    }

    type chainConfigs = ChainMap.t<chainConfig>
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
    type blockRangeFetchResponse<'a, 'b> = {
      currentBlockHeight: int,
      reorgGuard: reorgGuard,
      parsedQueueItems: array<Types.eventBatchQueueItem>,
      fromBlockQueried: int,
      heighestQueriedBlockNumber: int,
      latestFetchedBlockTimestamp: int,
      stats: blockRangeFetchStats,
      fetchStateRegisterId: FetchState.id,
      worker: Config.source<'a, 'b>,
    }
  }
}
