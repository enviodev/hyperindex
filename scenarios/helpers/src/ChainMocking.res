module Crypto = {
  type t
  @module external crypto: t = "crypto"

  type hashAlgo = | @as("sha3-256") Sha3_256

  type hash
  @send external createHash: (t, hashAlgo) => hash = "createHash"

  type hashedData
  @send external update: (hash, string) => hashedData = "update"

  type digestOptions = | @as("hex") Hex
  @send external digest: (hashedData, digestOptions) => string = "digest"

  let pad = s => "0x" ++ s

  let hashKeccak256 = (input, ~toString) =>
    crypto
    ->createHash(Sha3_256)
    ->update(input->toString)
    ->digest(Hex)
    ->pad

  let hashKeccak256String = hashKeccak256(~toString=Obj.magic)
  let hashKeccak256Int = hashKeccak256(~toString=Int.toString)
  let anyToString = a => a->Js.Json.stringifyAny->Option.getExn
  let hashKeccak256Any = hashKeccak256(~toString=anyToString)
  let hashKeccak256Compound = (previousHash, input) =>
    input->hashKeccak256(~toString=v => anyToString(v) ++ previousHash)
}

module Make = (Indexer: Indexer.S) => {
  open Indexer
  type log = {
    eventBatchQueueItem: Types.eventBatchQueueItem,
    srcAddress: Ethers.ethAddress,
    transactionHash: string,
    eventName: Types.eventName,
  }

  let eventConstructor = (
    ~params,
    ~accessor,
    ~srcAddress,
    ~chainId,
    ~txOrigin,
    ~blockNumber,
    ~blockTimestamp,
    ~blockHash,
    ~transactionHash,
    ~transactionIndex,
    ~logIndex,
  ): Types.event =>
    {
      Types.params,
      srcAddress,
      chainId,
      txOrigin,
      blockNumber,
      blockTimestamp,
      blockHash,
      transactionHash,
      transactionIndex,
      logIndex,
    }->accessor

  type makeEvent = (~blockHash: string) => Types.event

  type logConstructor = {
    transactionHash: string,
    makeEvent: makeEvent,
    logIndex: int,
    srcAddress: Ethers.ethAddress,
    eventName: Types.eventName,
  }
  type composedEventConstructor = (
    ~chainId: int,
    ~blockTimestamp: int,
    ~blockNumber: int,
    ~transactionIndex: int,
    ~txOrigin: option<Ethers.ethAddress>,
    ~logIndex: int,
  ) => logConstructor

  let makeEventConstructor = (
    ~accessor,
    ~params,
    ~serializer,
    ~eventName,
    ~srcAddress,
    ~chainId,
    ~blockTimestamp,
    ~blockNumber,
    ~transactionIndex,
    ~txOrigin,
    ~logIndex,
  ) => {
    let transactionHash =
      Crypto.hashKeccak256Any(params->serializer)
      ->Crypto.hashKeccak256Compound(transactionIndex)
      ->Crypto.hashKeccak256Compound(blockNumber)

    let makeEvent: makeEvent = eventConstructor(
      ~accessor,
      ~params,
      ~transactionIndex,
      ~logIndex,
      ~transactionHash,
      ~srcAddress,
      ~chainId,
      ~txOrigin,
      ~blockNumber,
      ~blockTimestamp,
    )

    {transactionHash, makeEvent, logIndex, srcAddress, eventName}
  }

  type block = {
    blockNumber: int,
    blockTimestamp: int,
    blockHash: string,
    logs: array<log>,
  }

  type t = {
    chainConfig: Config.chainConfig,
    blocks: array<block>,
    maxBlocksReturned: int,
    blockTimestampInterval: int,
  }

  let make = (~chainConfig, ~maxBlocksReturned, ~blockTimestampInterval) => {
    chainConfig,
    blocks: [],
    maxBlocksReturned,
    blockTimestampInterval,
  }

  let getLast = arr => arr->Array.get(arr->Array.length - 1)

  let getBlockHash = (~previousHash, ~logConstructors: array<logConstructor>) =>
    logConstructors->Array.reduce(previousHash, (accum, current) => {
      accum->Crypto.hashKeccak256Compound(current.transactionHash)
    })

  let zeroKeccak = Crypto.hashKeccak256Int(0)
  let addBlock = (self: t, ~makeLogConstructors: array<composedEventConstructor>) => {
    let lastBlock = self.blocks->getLast
    let (previousHash, blockNumber, blockTimestamp) = switch lastBlock {
    | None => (zeroKeccak, 0, 0)
    | Some({blockHash, blockNumber, blockTimestamp}) => (
        blockHash,
        blockNumber + 1,
        blockTimestamp + self.blockTimestampInterval,
      )
    }
    let logConstructors =
      makeLogConstructors->Array.mapWithIndex((i, x) =>
        x(
          ~transactionIndex=i,
          ~logIndex=i,
          ~chainId=self.chainConfig.chain->ChainMap.Chain.toChainId,
          ~txOrigin=None,
          ~blockNumber,
          ~blockTimestamp,
        )
      )

    let blockHash = getBlockHash(~previousHash, ~logConstructors)

    let logs = logConstructors->Array.map(({
      makeEvent,
      logIndex,
      srcAddress,
      transactionHash,
      eventName,
    }) => {
      let event: Types.event = makeEvent(~blockHash)
      let log: Types.eventBatchQueueItem = {
        event,
        chain: self.chainConfig.chain,
        timestamp: blockTimestamp,
        blockNumber,
        logIndex,
      }
      {eventBatchQueueItem: log, srcAddress, transactionHash, eventName}
    })

    let block = {blockNumber, blockTimestamp, blockHash, logs}

    {...self, blocks: self.blocks->Array.concat([block])}
  }

  let getHeight = (self: t) =>
    self.blocks
    ->getLast
    ->Option.mapWithDefault(0, b => b.blockNumber)

  let getBlocks = (self: t, ~fromBlock, ~toBlock) => {
    self.blocks
    ->Array.keep(b => b.blockNumber >= fromBlock && b.blockNumber <= toBlock)
    ->Array.keepWithIndex((_, i) => i < self.maxBlocksReturned)
  }

  let getBlock = (self: t, ~blockNumber) =>
    self.blocks->Js.Array2.find(b => b.blockNumber == blockNumber)

  let arrayHas = (arr, v) => arr->Js.Array2.find(item => item == v)->Option.isSome
  let getLogsFromBlocks = (~srcAddresses, ~eventNames, blocks: array<block>) => {
    blocks->Array.flatMap(b =>
      b.logs->Array.keepMap(l => {
        if srcAddresses->arrayHas(l.srcAddress) && eventNames->arrayHas(l.eventName) {
          Some(l.eventBatchQueueItem)
        } else {
          None
        }
      })
    )
  }

  let executeQuery = (
    self: t,
    query: FetchState.nextQuery,
  ): ChainWorkerTypes.blockRangeFetchResponse<_> => {
    let unfilteredBlocks = self->getBlocks(~fromBlock=query.fromBlock, ~toBlock=query.toBlock)
    let heighstBlock = unfilteredBlocks->getLast->Option.getExn
    let parentHash = self->getBlock(~blockNumber=query.fromBlock - 1)->Option.map(b => b.blockHash)
    let currentBlockHeight = self->getHeight

    let srcAddresses = query.contractAddressMapping->ContractAddressingMap.getAllAddresses
    let eventNames = self.chainConfig.contracts->Array.flatMap(c => c.events)
    let parsedQueueItemsPreFilter = unfilteredBlocks->getLogsFromBlocks(~srcAddresses, ~eventNames)
    let parsedQueueItems = switch query.eventFilters {
    | None => parsedQueueItemsPreFilter
    | Some(eventFilters) =>
      parsedQueueItemsPreFilter->Array.keep(FetchState.applyFilters(~eventFilters))
    }

    {
      currentBlockHeight,
      reorgGuard: {
        lastBlockScannedData: {
          blockHash: heighstBlock.blockHash,
          blockNumber: heighstBlock.blockNumber,
          blockTimestamp: heighstBlock.blockTimestamp,
        },
        parentHash,
      },
      parsedQueueItems,
      fromBlockQueried: query.fromBlock,
      heighestQueriedBlockNumber: heighstBlock.blockNumber,
      latestFetchedBlockTimestamp: heighstBlock.blockTimestamp,
      stats: "NO_STATS"->Obj.magic,
      fetchStateRegisterId: query.fetchStateRegisterId,
      worker: HyperSync(self->Obj.magic),
    }
  }

  let getBlockHashes = (self: t, ~blockNumbers) => {
    blockNumbers->Array.keepMap(blockNumber =>
      self
      ->getBlock(~blockNumber)
      ->Option.map(({blockTimestamp, blockHash, blockNumber}) => {
        ReorgDetection.blockTimestamp,
        blockHash,
        blockNumber,
      })
    )
  }
}
