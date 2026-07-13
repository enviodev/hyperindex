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
  let anyToString = a => a->JSON.stringifyAny->Option.getOrThrow
  let hashKeccak256Any = hashKeccak256(~toString=anyToString, _)
  let hashKeccak256Compound = (previousHash, input) =>
    input->hashKeccak256(~toString=v => anyToString(v) ++ previousHash)
}

module Make = () => {
  type log = {
    item: Internal.item,
    srcAddress: Address.t,
    transactionHash: string,
  }

  type makeEvent = (~blockHash: string) => Internal.eventPayload

  type logConstructor = {
    transactionHash: string,
    makeEvent: makeEvent,
    logIndex: int,
    srcAddress: Address.t,
    onEventRegistration: Internal.evmOnEventRegistration,
    transactionIndex: int,
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
    ~onEventRegistration: Internal.evmOnEventRegistration,
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
        params->RescriptSchema.S.reverseConvertToJsonOrThrow(
          onEventRegistration.eventConfig.paramsRawEventSchema,
        ),
      )
      ->Crypto.hashKeccak256Compound(transactionIndex)
      ->Crypto.hashKeccak256Compound(blockNumber)

    let transaction = makeTransaction(~transactionIndex, ~transactionHash)
    let makeEvent: makeEvent = (~blockHash) => {
      let block = makeBlock(~blockHash, ~blockNumber, ~blockTimestamp)
      {
        contractName: onEventRegistration.eventConfig.contractName,
        eventName: onEventRegistration.eventConfig.name,
        params,
        srcAddress,
        chainId,
        block,
        transaction,
        logIndex,
      }->Evm.fromPayload
    }

    {
      transactionHash,
      makeEvent,
      logIndex,
      srcAddress,
      onEventRegistration,
      transactionIndex,
    }
  }

  type block = {
    blockNumber: int,
    blockTimestamp: int,
    blockHash: string,
    logs: array<log>,
  }

  type t = {
    chainConfig: Config.chain,
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
      makeLogConstructors->Array.mapWithIndex((x, i) =>
        x(
          ~transactionIndex=i,
          ~logIndex=i,
          ~chainId=self.chainConfig.id,
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
      onEventRegistration,
      transactionIndex,
    }): log => {
      let log = Internal.Event({
        onEventRegistration: (onEventRegistration :> Internal.onEventRegistration),
        payload: makeEvent(~blockHash),
        chain: ChainMap.Chain.makeUnsafe(~chainId=self.chainConfig.id),
        blockNumber,
        logIndex,
        transactionIndex,
      })
      {item: log, srcAddress, transactionHash}
    })

    let block = {blockNumber, blockTimestamp, blockHash, logs}

    {...self, blocks: self.blocks->Array.concat([block])}
  }

  let getHeight = (self: t) =>
    self.blocks
    ->getLast
    ->Option.mapOr(0, b => b.blockNumber)

  let getBlocks = (self: t, ~fromBlock, ~toBlock) => {
    self.blocks
    ->Array.filter(b =>
      b.blockNumber >= fromBlock &&
        switch toBlock {
        | Some(toBlock) => b.blockNumber <= toBlock
        | None => true
        }
    )
    ->Array.filterWithIndex((_, i) => i < self.maxBlocksReturned)
  }

  let getBlock = (self: t, ~blockNumber) =>
    self.blocks->Array.find(b => b.blockNumber == blockNumber)

  let arrayHas = (arr, v) => arr->Array.find(item => item == v)->Option.isSome

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
      b.logs->Array.filterMap(l => {
        let isLogInConfig = addressesAndEventNames->Array.reduce(
          false,
          (prev, {addresses, eventKeys}) => {
            prev ||
            (addresses->arrayHas(l.srcAddress) &&
              eventKeys->arrayHas(
                getEventKey((l.item->Internal.castUnsafeEventItem).onEventRegistration.eventConfig),
              ))
          },
        )
        if isLogInConfig {
          Some(l)
        } else {
          None
        }
      })
    )
  }

  let executeQuery = (self: t, query: FetchState.query): Source.blockRangeFetchResponse => {
    let {fromBlock, toBlock} = query

    let unfilteredBlocks = self->getBlocks(~fromBlock, ~toBlock)
    let heighstBlock = unfilteredBlocks->getLast->Option.getOrThrow
    let knownHeight = self->getHeight

    let observedBlocks = unfilteredBlocks->Array.map((b): BlockStore.inputBlock => {
      blockNumber: b.blockNumber,
      blockHash: b.blockHash,
      blockTimestamp: b.blockTimestamp,
    })
    switch self->getBlock(~blockNumber=fromBlock - 1) {
    | Some(b) =>
      observedBlocks
      ->Array.unshift({
        BlockStore.blockNumber: b.blockNumber,
        blockHash: b.blockHash,
        blockTimestamp: b.blockTimestamp,
      })
      ->ignore
    | None => ()
    }

    let addressesAndEventNames = self.chainConfig.contracts->Array.map(c => {
      let addresses = query.addressesByContractName->Dict.get(c.name)->Option.getOr([])
      {
        addresses,
        eventKeys: c.events->Array.map(eventConfig => {
          eventConfig->getEventKey
        }),
      }
    })

    let pageLogs = unfilteredBlocks->getLogsFromBlocks(~addressesAndEventNames)
    let parsedQueueItems = pageLogs->Array.map(l => l.item)

    {
      knownHeight,
      parsedQueueItems,
      // Mock events carry their transaction and block inline on the payload;
      // the block page carries only the observed hashes for reorg detection.
      transactionStore: None,
      blockStore: BlockStore.fromJs(observedBlocks, ~ecosystem=Evm, ~shouldChecksum=false),
      fromBlockQueried: fromBlock,
      latestFetchedBlockNumber: heighstBlock.blockNumber,
      latestFetchedBlockTimestamp: heighstBlock.blockTimestamp,
      stats: (
        {
          totalTimeElapsed: 0.,
        }: Source.blockRangeFetchStats
      ),
      requestStats: [],
    }
  }

  let getBlockHashes = (self: t, ~blockNumbers) => {
    blockNumbers->Array.filterMap(blockNumber =>
      self
      ->getBlock(~blockNumber)
      ->Option.map(({
        blockTimestamp,
        blockHash,
        blockNumber,
      }): BlockStore.inputBlock => {
        blockTimestamp,
        blockHash,
        blockNumber,
      })
    )
  }
}
