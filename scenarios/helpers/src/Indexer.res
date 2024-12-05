module type S = {
  module ErrorHandling: {
    type t
  }

  module Types: {
    module HandlerTypes: {
      module Register: {
        type t<'eventArgs>

        let getLoader: t<'eventArgs> => option<Internal.loader>
        let getHandler: t<'eventArgs> => option<Internal.handler>
        let getContractRegister: t<'eventArgs> => option<Internal.contractRegister>
      }
    }

    module SingleOrMultiple: {
      type t<'a>
    }

    module type Event = {
      let sighash: string
      let topicCount: int
      let name: string
      let contractName: string
      type eventArgs
      let paramsRawEventSchema: RescriptSchema.S.schema<eventArgs>
      let convertHyperSyncEventArgs: HyperSyncClient.Decoder.decodedEvent => eventArgs
      let handlerRegister: HandlerTypes.Register.t<eventArgs>
      type eventFilter
      let getTopicSelection: SingleOrMultiple.t<eventFilter> => array<LogSelection.topicSelection>
    }
    module type InternalEvent = Event with type eventArgs = Internal.eventParams
  }

  module ContractAddressingMap: {
    type mapping
    let getAllAddresses: mapping => array<Address.t>
    let getAddressesFromContractName: (mapping, ~contractName: string) => array<Address.t>
  }

  module FetchState: {
    type id
    type nextQuery = {
      fetchStateRegisterId: id,
      partitionId: int,
      fromBlock: int,
      toBlock: option<int>,
      contractAddressMapping: ContractAddressingMap.mapping,
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
      parsedQueueItems: array<Internal.eventItem>,
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
        ~isPreRegisteringDynamicContracts: bool,
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

    type syncSource = HyperSync | HyperFuel | Rpc

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
