open Vitest

// A subgraph run holds far more per fetched event than a handler run: the
// payload, a register pass and its pending contract calls. Venus on BSC fetched
// 30 responses of 17,000 events each while the pool believed it had room,
// because the pool priced a query at its density estimate and a response that
// landed bigger left its register passes unaccounted. Two fixes: the pool is a
// tenth of the size in subgraph mode, and a response keeps its real size
// reserved until its passes are done.
describe("fetch buffer back-pressure for subgraph runs", () => {
  let baseChainConfig = TestConfig.default.chainMap->ChainMap.values->Utils.Array.firstUnsafe

  let makeChainState = () => {
    let addressStore = AddressStore.make(~ecosystem=Evm, ~contracts=[])
    let base = FetchState.make(
      ~onEventRegistrations=[],
      ~addressStore,
      ~addressRows=AddressRows.emptySeedRows(),
      ~onBlockRegistrations=[
        {
          Internal.index: 0,
          name: "reorg-threshold-test",
          chainId: baseChainConfig.id,
          startBlock: None,
          endBlock: None,
          interval: 1,
          blockFieldMask: None,
          handler: "mock onBlock handler"->(
            Utils.magic: string => Internal.onBlockArgs => promise<unit>
          ),
        },
      ],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=3,
      ~maxOnBlockBufferSize=10000,
      ~chainId=baseChainConfig.id,
      ~knownHeight=0,
      ~onNotice=_ => (),
    )
    let blockStore = BlockStore.make(~ecosystem=Svm)
    let fetchState = {...base, FetchState.knownHeight: 500}
    let mockSource = MockSource.make([], ~chainId=1)
    let cs = ChainState.make(
      ~chainConfig=baseChainConfig,
      ~fetchState,
      ~addressStore,
      ~sourceManager=SourceManager.make(
        ~sources=[mockSource.source],
        ~logger=Logger.makeInMemory(),
        ~isRealtime=false,
      ),
      ~shouldRollbackOnReorg=true,
      ~maxReorgDepth=200,
      ~committedProgressBlockNumber=-1,
      ~blockStore,
      ~logger=Logger.makeInMemory(),
    )
    (cs, fetchState)
  }

  it("sizes the pool for a subgraph run unless the operator set one", t => {
    let before = Env.subgraphMode.contents
    let handlerRun = CrossChainState.calculateTargetBufferSize()
    Env.subgraphMode := true
    let subgraphRun = CrossChainState.calculateTargetBufferSize()
    Env.subgraphMode := before
    t.expect((handlerRun, subgraphRun)).toEqual((100_000, 10_000))
  })

  it("keeps a response's size beyond its estimate reserved while its passes run", t => {
    let (cs, _) = makeChainState()
    cs->ChainState.holdExtraBudget(~items=17_000)
    let held = cs->ChainState.pendingBudget
    cs->ChainState.releaseExtraBudget(~items=17_000)
    let released = cs->ChainState.pendingBudget
    // A rollback that reset the reservations meanwhile leaves nothing to go negative.
    cs->ChainState.releaseExtraBudget(~items=5)
    t.expect((held, released, cs->ChainState.pendingBudget)).toEqual((17_000., 0., 0.))
  })
})
