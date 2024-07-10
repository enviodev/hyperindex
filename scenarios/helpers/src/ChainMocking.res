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

  let hashKeccak256String = hashKeccak256(~toString=int => int->Obj.magic, _)
  let hashKeccak256Int = hashKeccak256(~toString=int => int->Int.toString, _)
  let anyToString = a => a->Js.Json.stringifyAny->Option.getExn
  let hashKeccak256Any = hashKeccak256(~toString=anyToString, _)
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
    ~block,
    ~transaction,
    ~logIndex,
  ): Types.event =>
    {
      Types.params,
      srcAddress,
      chainId,
      block,
      transaction,
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
    ~logIndex: int,
  ) => logConstructor

  let makeEventConstructor = (
    ~accessor,
    ~params,
    ~schema,
    ~eventName,
    ~srcAddress,
    ~makeBlock: (
      ~blockNumber: int,
      ~blockTimestamp: int,
      ~blockHash: string,
    ) => Indexer.Types.Block.t,
    ~makeTransaction: (
      ~transactionIndex: int,
      ~transactionHash: string,
    ) => Indexer.Types.Transaction.t,
    ~chainId,
    ~blockTimestamp: int,
    ~blockNumber: int,
    ~transactionIndex,
    ~logIndex,
  ) => {
    let transactionHash =
      Crypto.hashKeccak256Any(params->RescriptSchema.S.serializeOrRaiseWith(schema))
      ->Crypto.hashKeccak256Compound(transactionIndex)
      ->Crypto.hashKeccak256Compound(blockNumber)

    let makeEvent: makeEvent = (~blockHash) => {
      let block = makeBlock(~blockHash, ~blockNumber, ~blockTimestamp)
      eventConstructor(
        ~params,
        ~accessor,
        ~srcAddress,
        ~chainId,
        ~block,
        ~logIndex,
        ~transaction=makeTransaction(~transactionIndex, ~transactionHash),
      )
    }

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

  type contractAddressesAndEventNames = {
    addresses: array<Ethers.ethAddress>,
    eventNames: array<Types.eventName>,
  }

  let getLogsFromBlocks = (
    blocks: array<block>,
    ~addressesAndEventNames: array<contractAddressesAndEventNames>,
  ) => {
    blocks->Array.flatMap(b =>
      b.logs->Array.keepMap(l => {
        let isLogInConfig = addressesAndEventNames->Array.reduce(
          false,
          (prev, {addresses, eventNames}) => {
            prev || (addresses->arrayHas(l.srcAddress) && eventNames->arrayHas(l.eventName))
          },
        )
        if isLogInConfig {
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
    let firstBlockParentNumberAndHash =
      self
      ->getBlock(~blockNumber=query.fromBlock - 1)
      ->Option.map(b => {ReorgDetection.blockNumber: b.blockNumber, blockHash: b.blockHash})
    let currentBlockHeight = self->getHeight

    let addressesAndEventNames = self.chainConfig.contracts->Array.map(c => {
      let addresses =
        query.contractAddressMapping->ContractAddressingMap.getAddressesFromContractName(
          ~contractName=c.name,
        )
      {addresses, eventNames: c.events}
    })

    let parsedQueueItemsPreFilter = unfilteredBlocks->getLogsFromBlocks(~addressesAndEventNames)
    let parsedQueueItems = switch query.eventFilters {
    | None => parsedQueueItemsPreFilter
    | Some(eventFilters) =>
      parsedQueueItemsPreFilter->Array.keep(i => i->FetchState.applyFilters(~eventFilters))
    }

    {
      currentBlockHeight,
      reorgGuard: {
        lastBlockScannedData: {
          blockHash: heighstBlock.blockHash,
          blockNumber: heighstBlock.blockNumber,
          blockTimestamp: heighstBlock.blockTimestamp,
        },
        firstBlockParentNumberAndHash,
      },
      parsedQueueItems,
      fromBlockQueried: query.fromBlock,
      heighestQueriedBlockNumber: heighstBlock.blockNumber,
      latestFetchedBlockTimestamp: heighstBlock.blockTimestamp,
      stats: "NO_STATS"->Obj.magic,
      fetchStateRegisterId: query.fetchStateRegisterId,
      partitionId: query.partitionId,
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
