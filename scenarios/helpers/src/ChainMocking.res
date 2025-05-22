module Utils = {
  external magic: 'a => 'b = "%identity"
}

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
    eventItem: Internal.eventItem,
    srcAddress: Address.t,
    transactionHash: string,
  }

  type makeEvent = (~blockHash: string) => Internal.event

  type logConstructor = {
    transactionHash: string,
    makeEvent: makeEvent,
    logIndex: int,
    srcAddress: Address.t,
    eventConfig: Internal.evmEventConfig,
  }

  type composedEventConstructor = (
    ~chainId: int,
    ~blockTimestamp: int,
    ~blockNumber: int,
    ~transactionIndex: int,
    ~logIndex: int,
  ) => logConstructor

  let makeEventConstructor = (
    ~params: Internal.eventParams,
    ~eventConfig: Internal.evmEventConfig,
    ~srcAddress,
    ~makeBlock: (
      ~blockNumber: int,
      ~blockTimestamp: int,
      ~blockHash: string,
    ) => Internal.eventBlock,
    ~makeTransaction: (
      ~transactionIndex: int,
      ~transactionHash: string,
    ) => Internal.eventTransaction,
    ~chainId,
    ~blockTimestamp: int,
    ~blockNumber: int,
    ~transactionIndex,
    ~logIndex,
  ) => {
    let transactionHash =
      Crypto.hashKeccak256Any(
        params->RescriptSchema.S.reverseConvertToJsonOrThrow(eventConfig.paramsRawEventSchema),
      )
      ->Crypto.hashKeccak256Compound(transactionIndex)
      ->Crypto.hashKeccak256Compound(blockNumber)

    let makeEvent: makeEvent = (~blockHash) => {
      let block = makeBlock(~blockHash, ~blockNumber, ~blockTimestamp)
      {
        params,
        srcAddress,
        chainId,
        block,
        transaction: makeTransaction(~transactionIndex, ~transactionHash),
        logIndex,
      }
    }

    {
      transactionHash,
      makeEvent,
      logIndex,
      srcAddress,
      eventConfig,
    }
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
      eventConfig,
    }): log => {
      let log: Internal.eventItem = {
        eventConfig: (eventConfig :> Internal.eventConfig),
        event: makeEvent(~blockHash),
        chain: self.chainConfig.chain,
        timestamp: blockTimestamp,
        blockNumber,
        logIndex,
      }
      {eventItem: log, srcAddress, transactionHash}
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
    ->Array.keep(b =>
      b.blockNumber >= fromBlock &&
        switch toBlock {
        | Some(toBlock) => b.blockNumber <= toBlock
        | None => true
        }
    )
    ->Array.keepWithIndex((_, i) => i < self.maxBlocksReturned)
  }

  let getBlock = (self: t, ~blockNumber) =>
    self.blocks->Js.Array2.find(b => b.blockNumber == blockNumber)

  let arrayHas = (arr, v) => arr->Js.Array2.find(item => item == v)->Option.isSome

  type contractAddressesAndEventNames = {
    addresses: array<Address.t>,
    eventKeys: array<string>,
  }

  let getEventKey = (eventConfig: Internal.eventConfig) => {
    eventConfig.contractName ++ "_" ++ eventConfig.id
  }

  let getLogsFromBlocks = (
    blocks: array<block>,
    ~addressesAndEventNames: array<contractAddressesAndEventNames>,
  ) => {
    blocks->Array.flatMap(b =>
      b.logs->Array.keepMap(l => {
        let isLogInConfig = addressesAndEventNames->Array.reduce(
          false,
          (prev, {addresses, eventKeys}) => {
            prev ||
            (addresses->arrayHas(l.srcAddress) &&
              eventKeys->arrayHas(getEventKey(l.eventItem.eventConfig)))
          },
        )
        if isLogInConfig {
          Some(l.eventItem)
        } else {
          None
        }
      })
    )
  }

  let executeQuery = (self: t, query: FetchState.query): Source.blockRangeFetchResponse => {
    let {fromBlock} = query
    let toBlock = switch query.target {
    | Head => None
    | EndBlock({toBlock})
    | Merge({toBlock}) =>
      Some(toBlock)
    }

    let unfilteredBlocks = self->getBlocks(~fromBlock, ~toBlock)
    let heighstBlock = unfilteredBlocks->getLast->Option.getExn
    let prevRangeLastBlock =
      self
      ->getBlock(~blockNumber=fromBlock - 1)
      ->Option.map(b => {ReorgDetection.blockNumber: b.blockNumber, blockHash: b.blockHash})
    let currentBlockHeight = self->getHeight

    let addressesAndEventNames = self.chainConfig.contracts->Array.map(c => {
      let addresses = query.addressesByContractName->Js.Dict.get(c.name)->Option.getWithDefault([])
      {
        addresses,
        eventKeys: c.events->Belt.Array.map(eventConfig => {
          eventConfig->getEventKey
        }),
      }
    })

    let parsedQueueItems = unfilteredBlocks->getLogsFromBlocks(~addressesAndEventNames)

    {
      currentBlockHeight,
      reorgGuard: {
        rangeLastBlock: {
          blockHash: heighstBlock.blockHash,
          blockNumber: heighstBlock.blockNumber,
        },
        prevRangeLastBlock,
      },
      parsedQueueItems,
      fromBlockQueried: fromBlock,
      latestFetchedBlockNumber: heighstBlock.blockNumber,
      latestFetchedBlockTimestamp: heighstBlock.blockTimestamp,
      stats: (
        {
          totalTimeElapsed: 0,
        }: Source.blockRangeFetchStats
      ),
    }
  }

  let getBlockHashes = (self: t, ~blockNumbers) => {
    blockNumbers->Array.keepMap(blockNumber =>
      self
      ->getBlock(~blockNumber)
      ->Option.map(({
        blockTimestamp,
        blockHash,
        blockNumber,
      }): ReorgDetection.blockDataWithTimestamp => {
        blockTimestamp,
        blockHash,
        blockNumber,
      })
    )
  }
}
