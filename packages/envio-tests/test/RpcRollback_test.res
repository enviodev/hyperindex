open Vitest

// Reorg detection and rollback-depth search driven by a real RpcSource talking
// to a real (mock) JSON-RPC server, rather than a source that fabricates its
// own responses. Every hash the store compares is one the source harvested from
// an actual eth_getLogs / eth_getBlockByNumber reply.
//
// Detection reads only this range's own responses — the logs' `blockHash` and
// the `parentHash` of the range's first block — so it sees the new chain as
// soon as it is served. The depth search that follows does go through the
// source's block cache, which still holds the abandoned fork, which is why
// `Rollback.rollback` drops it via `SourceManager.onReorg` before searching;
// the second case pins what that ordering buys.
//
// Separately, the source only harvests hashes from blocks it has a reason to
// fetch, so a reorg confined to a range with no logs is not detected at all.
// That gap is pre-existing and out of scope — this fixture keeps a log in every
// block of the reorged range.

let chainId = 1337->ChainId.fromInt
let sighash = "0xcf16a92280c1bbb43f72d31126b724d508df2877835849e8744017ab36a9b47f"
let contractAddress = "0x00000000000000000000000000000000000000AA"->String.toLowerCase
let transactionHash = "0x27e26f21f744064a4af53810d8002bbd7208a2ca4865503a99b9c529e5cff5ea"

// Full-width block hashes, so nothing depends on the store's short-hash padding.
// `fork` distinguishes the two chains a reorg picks between.
let blockHash = (~blockNumber, ~fork) =>
  "0x" ++ `${fork}${blockNumber->Int.toString}`->String.padStart(64, "0")

let hex = n => "0x" ++ n->Int.toString(~radix=16)

let topicSelection: Internal.resolvedTopicSelection = {
  topic0: [sighash->EvmTypes.Hex.fromStringUnsafe],
  topic1: Values([]),
  topic2: Values([]),
  topic3: Values([]),
}

let registration: Internal.evmOnEventRegistration = {
  ...EventRegistration.evmOnEventRegistration(
    ~id=sighash,
    ~blockFieldNames=[Number, Timestamp, Hash, ParentHash],
    ~transactionFieldNames=[],
    ~eventFilters=[topicSelection],
  ),
  index: 0,
}

let indexedAddresses: array<Internal.indexingAddress> = [
  {
    address: contractAddress->Address.unsafeFromString,
    contractName: registration.eventConfig.contractName,
    registrationBlock: -1,
  },
]

let addressStore = () =>
  TestAddresses.makeStore(
    ~onEventRegistrations=[(registration :> Internal.onEventRegistration)],
    ~shouldChecksum=false,
  )

// The chain the mock server currently serves. `forkFrom` is the first block
// whose hash comes from the second fork, which is exactly how a reorg looks to
// a client polling the same endpoint.
type serverState = {mutable height: int, mutable forkFrom: int}

let forkOf = (state, blockNumber) => blockNumber >= state.forkFrom ? "b" : "a"

let blockJson = (state, blockNumber) =>
  JSON.parseOrThrow(
    `{"number":"${blockNumber->hex}","timestamp":"${blockNumber->hex}","hash":"${blockHash(
        ~blockNumber,
        ~fork=state->forkOf(blockNumber),
      )}","parentHash":"${blockHash(
        ~blockNumber=blockNumber - 1,
        ~fork=state->forkOf(blockNumber - 1),
      )}"}`,
  )

// One log per block in the requested range, so every block in a fetched range
// contributes its hash to the page.
let logsJson = (state, ~fromBlock, ~toBlock) =>
  JSON.Array(
    Array.fromInitializer(~length=toBlock - fromBlock + 1, i => {
      let blockNumber = fromBlock + i
      JSON.parseOrThrow(
        `{"address":"${contractAddress}","topics":["${sighash}"],"data":"0x","blockNumber":"${blockNumber->hex}","transactionHash":"${transactionHash}","transactionIndex":"0x1","blockHash":"${blockHash(
            ~blockNumber,
            ~fork=state->forkOf(blockNumber),
          )}","logIndex":"0x0","removed":false}`,
      )
    }),
  )

let hexParam = json => {
  let quantity = json->JSON.Decode.string->Option.getOrThrow(~message="expected a hex quantity")
  quantity
  ->String.slice(~start=2, ~end=quantity->String.length)
  ->Int.fromString(~radix=16)
  ->Option.getOrThrow(~message="expected a parsable hex quantity")
}

let startServer = state =>
  MockRpcServer.makeWithParams(~getResult=(~method, ~params) => {
    let arg = i => params->JSON.Decode.array->Option.getOrThrow->Array.getUnsafe(i)
    switch method {
    | "eth_blockNumber" => JSON.String(state.height->hex)
    | "eth_getBlockByNumber" => state->blockJson(arg(0)->hexParam)
    | "eth_getLogs" =>
      let filter = arg(0)->JSON.Decode.object->Option.getOrThrow
      state->logsJson(
        ~fromBlock=filter->Dict.getUnsafe("fromBlock")->hexParam,
        ~toBlock=filter->Dict.getUnsafe("toBlock")->hexParam,
      )
    | _ => JsError.throwWithMessage(`Unexpected RPC method ${method}`)
    }
  })

let makeSource = (~url) =>
  RpcSource.make({
    url,
    chainId,
    onEventRegistrations: [registration],
    sourceFor: Sync,
    syncConfig: EvmChain.getSyncConfig({
      initialBlockInterval: 10,
      accelerationAdditive: 0,
      intervalCeiling: 10,
      backoffMillis: 1,
      queryTimeoutMillis: 5_000,
    }),
    lowercaseAddresses: true,
    addressStore: addressStore(),
  })

let fetchRange = (source: Source.t, ~fromBlock, ~toBlock, ~knownHeight) =>
  source.getItemsOrThrow(
    ~fromBlock,
    ~toBlock=Some(toBlock),
    ~addressSet=addressStore()->AddressStore.makeSet(
      ~contractName=registration.eventConfig.contractName,
    ),
    ~knownHeight,
    ~partitionId="0",
    ~selection={
      dependsOnAddresses: true,
      onEventRegistrations: [(registration :> Internal.onEventRegistration)],
    },
    ~itemsTarget=None,
    ~retry=0,
    ~logger=Logging.getLogger(),
  )

let makeChainState = (~source: Source.t, ~knownHeight) => {
  let chainConfig = TestConfig.make(~chainId=1337).chainMap->ChainMap.get(chainId)
  let store = addressStore()
  let fetchState = FetchState.make(
    ~onEventRegistrations=[(registration :> Internal.onEventRegistration)],
    ~addressStore=store,
    ~addressRows=TestAddresses.addressRows(
      ~addresses=indexedAddresses,
      ~onEventRegistrations=[(registration :> Internal.onEventRegistration)],
    ),
    ~onBlockRegistrations=[],
    ~startBlock=0,
    ~endBlock=None,
    ~maxAddrInPartition=10,
    ~maxOnBlockBufferSize=1000,
    ~chainId,
    ~knownHeight,
  )
  ChainState.make(
    ~chainConfig,
    ~fetchState={...fetchState, FetchState.knownHeight},
    ~addressStore=store,
    ~sourceManager=SourceManager.make(~sources=[source], ~isRealtime=false),
    ~shouldRollbackOnReorg=true,
    ~maxReorgDepth=200,
    ~committedProgressBlockNumber=-1,
    ~blockStore=BlockStore.make(~ecosystem=Evm, ~shouldChecksum=false),
    ~logger=Logging.getLogger(),
  )
}

describe("Rollback against a real RPC server", () => {
  Async.it("detects a reorg from fetched hashes and finds the rollback depth", async t => {
    let state = {height: 105, forkFrom: 999}
    let mock = await startServer(state)
    let source = makeSource(~url=mock.url)
    let chainState = makeChainState(~source, ~knownHeight=state.height)

    // Blocks 100-102 on the original chain.
    let page = await source->fetchRange(~fromBlock=100, ~toBlock=102, ~knownHeight=state.height)
    t.expect(
      chainState->ChainState.registerReorgGuard(~blockStore=page.blockStore, ~knownHeight=105),
      ~message="The first range has nothing to disagree with",
    ).toEqual(ReorgDetection.NoReorg)
    t.expect(
      chainState
      ->ChainState.blockStore
      ->BlockStore.getHashedBlockNumbers(~fromBlock=0, ~belowBlock=200),
      ~message="Every observed block contributes its own hash and its parent's",
    ).toEqual([99, 100, 101, 102])

    // The chain reorgs from 102 up, and the source refetches across the seam.
    state.forkFrom = 102
    let reorgedPage =
      await source->fetchRange(~fromBlock=103, ~toBlock=104, ~knownHeight=state.height)

    t.expect(
      chainState->ChainState.registerReorgGuard(
        ~blockStore=reorgedPage.blockStore,
        ~knownHeight=105,
      ),
      ~message="Block 102 arrives as the parent of 103 with the other fork's hash",
    ).toEqual(
      ReorgDetection.ReorgDetected({
        scannedBlock: {blockNumber: 102, blockHash: blockHash(~blockNumber=102, ~fork="a")},
        receivedBlock: {blockNumber: 102, blockHash: blockHash(~blockNumber=102, ~fork="b")},
      }),
    )

    // The depth search re-fetches the stored hashes below 102 over RPC. Only
    // 102 moved, so 101 is the deepest block both chains still agree on.
    let rollbackTarget = await Rollback.getLastKnownValidBlock(
      chainState,
      ~reorgBlockNumber=102,
      ~isRealtime=false,
    )
    t.expect(rollbackTarget).toEqual(101)

    await mock.closeAsync()
  })

  Async.it("drops the source's pre-reorg cache before searching for the fork", async t => {
    let state = {height: 105, forkFrom: 999}
    let mock = await startServer(state)
    let source = makeSource(~url=mock.url)
    let chainState = makeChainState(~source, ~knownHeight=state.height)

    let page = await source->fetchRange(~fromBlock=100, ~toBlock=102, ~knownHeight=state.height)
    t.expect(
      chainState->ChainState.registerReorgGuard(~blockStore=page.blockStore, ~knownHeight=105),
    ).toEqual(ReorgDetection.NoReorg)

    // The fork starts at 100. Block 99 was never cached (nothing fetched it),
    // so the search re-reads it fresh and it still matches; 100 and 101 were
    // cached while fetching, and that is what the search gets wrong.
    state.forkFrom = 100

    // Answering the depth search from the cache filled while fetching would
    // "confirm" blocks that no longer exist and stop 2 blocks past the fork.
    // `getLastKnownValidBlock` drops that cache itself before searching, so a
    // caller cannot forget to and get the shallow answer.
    let target = await Rollback.getLastKnownValidBlock(
      chainState,
      ~reorgBlockNumber=102,
      ~isRealtime=false,
    )
    t.expect(
      target,
      ~message="Refetched hashes place the fork at 100, so the rollback goes to 99",
    ).toEqual(99)

    await mock.closeAsync()
  })
})
