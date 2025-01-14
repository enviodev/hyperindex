module type S = {
  module ErrorHandling: {
    type t
  }

  module Types: {
    type loaderContext
    type handlerContext
    type contractRegistrations

    module HandlerTypes: {
      module Register: {
        type t

        let getLoader: t => option<Internal.loader>
        let getHandler: t => option<Internal.handler>
        let getContractRegister: t => option<Internal.contractRegister>
      }
    }

    module SingleOrMultiple: {
      type t<'a>
    }

    module type Event = {
      let sighash: string // topic0 for Evm and rb for Fuel receipts
      let topicCount: int // Number of topics for evm, always 0 for fuel
      let name: string
      let contractName: string

      type eventArgs
      type block
      type transaction

      type event = Internal.genericEvent<eventArgs, block, transaction>
      type loader<'loaderReturn> = Internal.genericLoader<
        Internal.genericLoaderArgs<event, loaderContext>,
        'loaderReturn,
      >
      type handler<'loaderReturn> = Internal.genericHandler<
        Internal.genericHandlerArgs<event, handlerContext, 'loaderReturn>,
      >
      type contractRegister = Internal.genericContractRegister<
        Internal.genericContractRegisterArgs<event, contractRegistrations>,
      >

      let paramsRawEventSchema: RescriptSchema.S.schema<eventArgs>
      let blockSchema: RescriptSchema.S.schema<block>
      let transactionSchema: RescriptSchema.S.schema<transaction>

      let convertHyperSyncEventArgs: HyperSyncClient.Decoder.decodedEvent => eventArgs
      let handlerRegister: HandlerTypes.Register.t

      type eventFilter
      let getTopicSelection: SingleOrMultiple.t<eventFilter> => array<LogSelection.topicSelection>
    }
    module type InternalEvent = Event
      with type eventArgs = Internal.eventParams
      and type transaction = Internal.eventTransaction
      and type block = Internal.eventBlock
  }

  module ContractAddressingMap: {
    type mapping
    let make: unit => mapping
    let getAllAddresses: mapping => array<Address.t>
    let getAddressesFromContractName: (mapping, ~contractName: string) => array<Address.t>
  }

  module FetchState: {
    type selection =
      | Wildcard({})
      | Normal({})

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

  module ChainWorker: {
    type blockRangeFetchStats
    type blockRangeFetchResponse = {
      currentBlockHeight: int,
      reorgGuard: ReorgDetection.reorgGuard,
      parsedQueueItems: array<Internal.eventItem>,
      fromBlockQueried: int,
      latestFetchedBlockNumber: int,
      latestFetchedBlockTimestamp: int,
      stats: blockRangeFetchStats,
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
        ~fromBlock: int,
        ~toBlock: option<int>,
        ~contractAddressMapping: ContractAddressingMap.mapping,
        ~currentBlockHeight: int,
        ~partitionId: string,
        ~selection: FetchState.selection,
        ~isPreRegisteringDynamicContracts: bool,
        ~logger: Pino.t,
      ) => promise<result<blockRangeFetchResponse, ErrorHandling.t>>
    }
  }

  module Config: {
    type contract = {
      name: string,
      abi: Ethers.abi,
      addresses: array<Address.t>,
      events: array<module(Types.Event)>,
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
