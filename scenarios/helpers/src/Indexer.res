module type S = {
  module ErrorHandling: {
    type t
  }

  module FetchState: {
    type indexingContract

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
      addressesByContractName: dict<array<Address.t>>,
      target: queryTarget,
      indexingContracts: dict<indexingContract>,
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
        ~addressesByContractName: dict<array<Address.t>>,
        ~indexingContracts: dict<FetchState.indexingContract>,
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
      startBlock: option<int>,
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
