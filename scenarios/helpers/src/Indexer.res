module type S = {
  module ErrorHandling: {
    type t
  }

  module ContractAddressingMap: {
    type mapping
    let make: unit => mapping
    let getAllAddresses: mapping => array<Address.t>
    let getAddressesFromContractName: (mapping, ~contractName: string) => array<Address.t>
  }

  module FetchState: {
    type selection = {
      eventConfigs: array<Internal.eventConfig>,
      dependsOnAddresses: bool,
    }

    type queryTarget =
      | Head
      | EndBlock({toBlock: int})
      | Merge({
          // The partition we are going to merge into
          // It shouldn't be fetching during the query
          intoPartitionId: string,
          toBlock: int,
        })

    type query = {
      partitionId: string,
      fromBlock: int,
      selection: selection,
      contractAddressMapping: ContractAddressingMap.mapping,
      target: queryTarget,
    }
  }

  module Source: {
    type blockRangeFetchStats = {
      @as("total time elapsed (ms)") totalTimeElapsed: int,
      @as("parsing time (ms)") parsingTimeElapsed?: int,
      @as("page fetch time (ms)") pageFetchTime?: int,
    }
    type blockRangeFetchResponse = {
      currentBlockHeight: int,
      reorgGuard: ReorgDetection.reorgGuard,
      parsedQueueItems: array<Internal.eventItem>,
      fromBlockQueried: int,
      latestFetchedBlockNumber: int,
      latestFetchedBlockTimestamp: int,
      stats: blockRangeFetchStats,
    }
    type sourceFor = Sync | Fallback
    type t = {
      name: string,
      sourceFor: sourceFor,
      chain: ChainMap.Chain.t,
      poweredByHyperSync: bool,
      /* Frequency (in ms) used when polling for new events on this network. */
      pollingInterval: int,
      getBlockHashes: (
        ~blockNumbers: array<int>,
        ~logger: Pino.t,
      ) => promise<result<array<ReorgDetection.blockDataWithTimestamp>, exn>>,
      getHeightOrThrow: unit => promise<int>,
      getItemsOrThrow: (
        ~fromBlock: int,
        ~toBlock: option<int>,
        ~contractAddressMapping: ContractAddressingMap.mapping,
        ~currentBlockHeight: int,
        ~partitionId: string,
        ~selection: FetchState.selection,
        ~retry: int,
        ~logger: Pino.t,
      ) => promise<blockRangeFetchResponse>,
    }
  }

  module Config: {
    type contract = {
      name: string,
      abi: Ethers.abi,
      addresses: array<Address.t>,
      events: array<Internal.eventConfig>,
    }

    type chainConfig = {
      startBlock: int,
      endBlock: option<int>,
      confirmedBlockThreshold: int,
      chain: ChainMap.Chain.t,
      contracts: array<contract>,
      sources: array<Source.t>,
    }
  }
}
