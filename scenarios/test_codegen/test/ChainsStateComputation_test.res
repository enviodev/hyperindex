open RescriptMocha

// Helper function to check if all chains are ready (synced/caught up to head or endblock)
let allChainsReady = (chains: Internal.chains): bool => {
  chains
  ->Js.Dict.values
  ->Belt.Array.every(chainInfo => chainInfo.isReady)
}

describe("Chains State Computation", () => {
  describe("computeChainsState", () => {
    it("should set isReady=true when all chains have reached their end block", () => {
      // Create mock chain fetchers that have all reached end block
      let chainFetcher1 = {
        "committedProgressBlockNumber": 1000,
        "fetchState": {
          "endBlock": Some(1000),
        },
        "timestampCaughtUpToHeadOrEndblock": Some(123456),
      }->Utils.magic

      let chainFetcher2 = {
        "committedProgressBlockNumber": 2000,
        "fetchState": {
          "endBlock": Some(2000),
        },
        "timestampCaughtUpToHeadOrEndblock": Some(123456),
      }->Utils.magic

      let chainFetchers =
        ChainMap.fromArrayUnsafe([
          (ChainMap.Chain.makeUnsafe(~chainId=1), chainFetcher1),
          (ChainMap.Chain.makeUnsafe(~chainId=2), chainFetcher2),
        ])

      let chains = EventProcessing.computeChainsState(chainFetchers)

      // Verify that both chains are marked as ready
      Assert.equal(chains->Js.Dict.get("1")->Belt.Option.map(c => c.isReady), Some(true))
      Assert.equal(chains->Js.Dict.get("2")->Belt.Option.map(c => c.isReady), Some(true))
      Assert.equal(allChainsReady(chains), true)
    })

    it("should set isReady=false when at least one chain has not reached end block", () => {
      // Chain 1 has reached end block, but chain 2 has not
      let chainFetcher1 = {
        "committedProgressBlockNumber": 1000,
        "fetchState": {
          "endBlock": Some(1000),
        },
        "timestampCaughtUpToHeadOrEndblock": Some(123456),
      }->Utils.magic

      let chainFetcher2 = {
        "committedProgressBlockNumber": 1500,
        "fetchState": {
          "endBlock": Some(2000), // Not yet reached
        },
        "timestampCaughtUpToHeadOrEndblock": None,
      }->Utils.magic

      let chainFetchers =
        ChainMap.fromArrayUnsafe([
          (ChainMap.Chain.makeUnsafe(~chainId=1), chainFetcher1),
          (ChainMap.Chain.makeUnsafe(~chainId=2), chainFetcher2),
        ])

      let chains = EventProcessing.computeChainsState(chainFetchers)

      // Chain 1 should be ready, chain 2 should not be ready
      Assert.equal(chains->Js.Dict.get("1")->Belt.Option.map(c => c.isReady), Some(true))
      Assert.equal(chains->Js.Dict.get("2")->Belt.Option.map(c => c.isReady), Some(false))
      Assert.equal(allChainsReady(chains), false)
    })

    it("should set isReady=false when a chain has no end block (live mode)", () => {
      // Chain with no end block set (continuous live indexing)
      let chainFetcher1 = {
        "committedProgressBlockNumber": 1000,
        "fetchState": {
          "endBlock": None, // Live mode, no end block
        },
        "timestampCaughtUpToHeadOrEndblock": None,
      }->Utils.magic

      let chainFetchers = ChainMap.fromArrayUnsafe([(ChainMap.Chain.makeUnsafe(~chainId=1), chainFetcher1)])

      let chains = EventProcessing.computeChainsState(chainFetchers)

      Assert.equal(chains->Js.Dict.get("1")->Belt.Option.map(c => c.isReady), Some(false))
      Assert.equal(allChainsReady(chains), false)
    })

    it("should set isReady=false when committedProgressBlockNumber is below endBlock", () => {
      let chainFetcher1 = {
        "committedProgressBlockNumber": 500,
        "fetchState": {
          "endBlock": Some(1000),
        },
        "timestampCaughtUpToHeadOrEndblock": None,
      }->Utils.magic

      let chainFetchers = ChainMap.fromArrayUnsafe([(ChainMap.Chain.makeUnsafe(~chainId=1), chainFetcher1)])

      let chains = EventProcessing.computeChainsState(chainFetchers)

      Assert.equal(chains->Js.Dict.get("1")->Belt.Option.map(c => c.isReady), Some(false))
      Assert.equal(allChainsReady(chains), false)
    })

    it("should set isReady=true when committedProgressBlockNumber exceeds endBlock", () => {
      // Progress can go beyond end block in some edge cases
      let chainFetcher1 = {
        "committedProgressBlockNumber": 1500,
        "fetchState": {
          "endBlock": Some(1000),
        },
        "timestampCaughtUpToHeadOrEndblock": Some(123456),
      }->Utils.magic

      let chainFetchers = ChainMap.fromArrayUnsafe([(ChainMap.Chain.makeUnsafe(~chainId=1), chainFetcher1)])

      let chains = EventProcessing.computeChainsState(chainFetchers)

      Assert.equal(chains->Js.Dict.get("1")->Belt.Option.map(c => c.isReady), Some(true))
      Assert.equal(allChainsReady(chains), true)
    })

    it("should handle empty chainFetchers map (edge case)", () => {
      let chainFetchers = ChainMap.fromArrayUnsafe([])

      let chains = EventProcessing.computeChainsState(chainFetchers)

      // Empty dict means no chains, which technically means "all chains are ready" (vacuous truth)
      Assert.equal(chains->Js.Dict.keys->Belt.Array.length, 0)
      Assert.equal(allChainsReady(chains), true)
    })

    it("should correctly track each chain state in multi-chain scenario when only some reached end", () => {
      let chainFetcher1 = {
        "committedProgressBlockNumber": 1000,
        "fetchState": {
          "endBlock": Some(1000), // Reached
        },
        "timestampCaughtUpToHeadOrEndblock": Some(123456),
      }->Utils.magic

      let chainFetcher2 = {
        "committedProgressBlockNumber": 1999,
        "fetchState": {
          "endBlock": Some(2000), // Not reached (1 block away)
        },
        "timestampCaughtUpToHeadOrEndblock": None,
      }->Utils.magic

      let chainFetcher3 = {
        "committedProgressBlockNumber": 3000,
        "fetchState": {
          "endBlock": Some(3000), // Reached
        },
        "timestampCaughtUpToHeadOrEndblock": Some(123456),
      }->Utils.magic

      let chainFetchers =
        ChainMap.fromArrayUnsafe([
          (ChainMap.Chain.makeUnsafe(~chainId=1), chainFetcher1),
          (ChainMap.Chain.makeUnsafe(~chainId=2), chainFetcher2),
          (ChainMap.Chain.makeUnsafe(~chainId=3), chainFetcher3),
        ])

      let chains = EventProcessing.computeChainsState(chainFetchers)

      // Verify individual chain states
      Assert.equal(chains->Js.Dict.get("1")->Belt.Option.map(c => c.isReady), Some(true))
      Assert.equal(chains->Js.Dict.get("2")->Belt.Option.map(c => c.isReady), Some(false))
      Assert.equal(chains->Js.Dict.get("3")->Belt.Option.map(c => c.isReady), Some(true))
      Assert.equal(allChainsReady(chains), false)
    })

    it("should mark all chains as ready only when ALL chains in multi-chain scenario reached end", () => {
      let chainFetcher1 = {
        "committedProgressBlockNumber": 1000,
        "fetchState": {
          "endBlock": Some(1000),
        },
        "timestampCaughtUpToHeadOrEndblock": Some(123456),
      }->Utils.magic

      let chainFetcher2 = {
        "committedProgressBlockNumber": 2000,
        "fetchState": {
          "endBlock": Some(2000),
        },
        "timestampCaughtUpToHeadOrEndblock": Some(123456),
      }->Utils.magic

      let chainFetcher3 = {
        "committedProgressBlockNumber": 3000,
        "fetchState": {
          "endBlock": Some(3000),
        },
        "timestampCaughtUpToHeadOrEndblock": Some(123456),
      }->Utils.magic

      let chainFetchers =
        ChainMap.fromArrayUnsafe([
          (ChainMap.Chain.makeUnsafe(~chainId=1), chainFetcher1),
          (ChainMap.Chain.makeUnsafe(~chainId=2), chainFetcher2),
          (ChainMap.Chain.makeUnsafe(~chainId=3), chainFetcher3),
        ])

      let chains = EventProcessing.computeChainsState(chainFetchers)

      // All chains should be ready
      Assert.equal(chains->Js.Dict.get("1")->Belt.Option.map(c => c.isReady), Some(true))
      Assert.equal(chains->Js.Dict.get("2")->Belt.Option.map(c => c.isReady), Some(true))
      Assert.equal(chains->Js.Dict.get("3")->Belt.Option.map(c => c.isReady), Some(true))
      Assert.equal(allChainsReady(chains), true)
    })
  })

  describe("chains state in processEventBatch", () => {
    // These tests actually invoke EventProcessing.processEventBatch and verify
    // that it correctly passes chains state to handlers based on chainFetchers state

    Async.it("should pass chains with isReady=false when chains have not reached end block", async () => {
      EventHandlers.lastEmptyEventChains := None

      // Setup: chain has NOT reached its end block (500 < 1000)
      let chainFetcher = {
        "committedProgressBlockNumber": 500,
        "fetchState": {"endBlock": Some(1000)},
        "timestampCaughtUpToHeadOrEndblock": None,
      }->Utils.magic
      let chainFetchers = ChainMap.fromArrayUnsafe([(ChainMap.Chain.makeUnsafe(~chainId=54321), chainFetcher)])

      let config = RegisterHandlers.registerAllHandlers()
      let inMemoryStore = InMemoryStore.make()
      let loadManager = LoadManager.make()

      // Create an EmptyEvent that will trigger our handler
      let emptyEventLog: Types.eventLog<Types.Gravatar.EmptyEvent.eventArgs> = {
        params: (),
        chainId: 54321,
        srcAddress: "0xabc0000000000000000000000000000000000000"->Address.Evm.fromStringOrThrow,
        logIndex: 1,
        transaction: MockEvents.tx1,
        block: MockEvents.block1,
      }

      let item = Internal.Event({
        timestamp: emptyEventLog.block.timestamp,
        chain: ChainMap.Chain.makeUnsafe(~chainId=54321),
        blockNumber: emptyEventLog.block.number,
        logIndex: emptyEventLog.logIndex,
        eventConfig: (Types.Gravatar.EmptyEvent.register() :> Internal.eventConfig),
        event: emptyEventLog->Internal.fromGenericEvent,
      })

      // Actually call processEventBatch - the real code path
      let _ = (await EventProcessing.processEventBatch(
        ~items=[item],
        ~progressedChains=[{
          chainId: 54321,
          batchSize: 1,
          progressBlockNumber: 500,
          isProgressAtHead: false,
          totalEventsProcessed: 1,
        }],
        ~inMemoryStore,
        ~isInReorgThreshold=false,
        ~loadManager,
        ~config,
        ~chainFetchers,
      ))->Belt.Result.getExn

      // Assert on the chains state that processEventBatch passed to the handler
      switch EventHandlers.lastEmptyEventChains.contents {
      | Some(chains) => {
          // Verify chain 54321 exists and is not ready
          Assert.equal(chains->Js.Dict.get("54321")->Belt.Option.map(c => c.isReady), Some(false))
          Assert.equal(allChainsReady(chains), false)
        }
      | None => Assert.fail("Handler was not called - processEventBatch didn't execute handler")
      }
    })

    Async.it("should pass chains with isReady=true when all chains have reached end block", async () => {
      EventHandlers.lastEmptyEventChains := None

      // Setup: chain HAS reached its end block (1000 >= 1000)
      let chainFetcher = {
        "committedProgressBlockNumber": 1000,
        "fetchState": {"endBlock": Some(1000)},
        "timestampCaughtUpToHeadOrEndblock": Some(123456),
      }->Utils.magic
      let chainFetchers = ChainMap.fromArrayUnsafe([(ChainMap.Chain.makeUnsafe(~chainId=54321), chainFetcher)])

      let config = RegisterHandlers.registerAllHandlers()
      let inMemoryStore = InMemoryStore.make()
      let loadManager = LoadManager.make()

      let emptyEventLog: Types.eventLog<Types.Gravatar.EmptyEvent.eventArgs> = {
        params: (),
        chainId: 54321,
        srcAddress: "0xabc0000000000000000000000000000000000000"->Address.Evm.fromStringOrThrow,
        logIndex: 1,
        transaction: MockEvents.tx1,
        block: MockEvents.block1,
      }

      let item = Internal.Event({
        timestamp: emptyEventLog.block.timestamp,
        chain: ChainMap.Chain.makeUnsafe(~chainId=54321),
        blockNumber: emptyEventLog.block.number,
        logIndex: emptyEventLog.logIndex,
        eventConfig: (Types.Gravatar.EmptyEvent.register() :> Internal.eventConfig),
        event: emptyEventLog->Internal.fromGenericEvent,
      })

      // Actually call processEventBatch
      let _ = (await EventProcessing.processEventBatch(
        ~items=[item],
        ~progressedChains=[{
          chainId: 54321,
          batchSize: 1,
          progressBlockNumber: 1000,
          isProgressAtHead: true,
          totalEventsProcessed: 1,
        }],
        ~inMemoryStore,
        ~isInReorgThreshold=false,
        ~loadManager,
        ~config,
        ~chainFetchers,
      ))->Belt.Result.getExn

      // Assert on what processEventBatch actually passed to the handler
      switch EventHandlers.lastEmptyEventChains.contents {
      | Some(chains) => {
          // Verify chain 54321 exists and is ready
          Assert.equal(chains->Js.Dict.get("54321")->Belt.Option.map(c => c.isReady), Some(true))
          Assert.equal(allChainsReady(chains), true)
        }
      | None => Assert.fail("Handler was not called")
      }
    })

    Async.it("should pass correct per-chain state in multi-chain when not all reached end", async () => {
      EventHandlers.lastEmptyEventChains := None

      // Setup: chain 1 reached end, chain 2 has not
      let chainFetcher1 = {
        "committedProgressBlockNumber": 1000,
        "fetchState": {"endBlock": Some(1000)},
        "timestampCaughtUpToHeadOrEndblock": Some(123456),
      }->Utils.magic
      let chainFetcher2 = {
        "committedProgressBlockNumber": 1500,
        "fetchState": {"endBlock": Some(2000)},
        "timestampCaughtUpToHeadOrEndblock": None,
      }->Utils.magic
      let chainFetchers = ChainMap.fromArrayUnsafe([
        (ChainMap.Chain.makeUnsafe(~chainId=1), chainFetcher1),
        (ChainMap.Chain.makeUnsafe(~chainId=2), chainFetcher2),
      ])

      let config = RegisterHandlers.registerAllHandlers()
      let inMemoryStore = InMemoryStore.make()
      let loadManager = LoadManager.make()

      let emptyEventLog: Types.eventLog<Types.Gravatar.EmptyEvent.eventArgs> = {
        params: (),
        chainId: 1,
        srcAddress: "0xabc0000000000000000000000000000000000000"->Address.Evm.fromStringOrThrow,
        logIndex: 1,
        transaction: MockEvents.tx1,
        block: MockEvents.block1,
      }

      let item = Internal.Event({
        timestamp: emptyEventLog.block.timestamp,
        chain: ChainMap.Chain.makeUnsafe(~chainId=1),
        blockNumber: emptyEventLog.block.number,
        logIndex: emptyEventLog.logIndex,
        eventConfig: (Types.Gravatar.EmptyEvent.register() :> Internal.eventConfig),
        event: emptyEventLog->Internal.fromGenericEvent,
      })

      // Call the real processEventBatch with multi-chain scenario
      let _ = (await EventProcessing.processEventBatch(
        ~items=[item],
        ~progressedChains=[{
          chainId: 1,
          batchSize: 1,
          progressBlockNumber: 1000,
          isProgressAtHead: false,
          totalEventsProcessed: 1,
        }],
        ~inMemoryStore,
        ~isInReorgThreshold=false,
        ~loadManager,
        ~config,
        ~chainFetchers,
      ))->Belt.Result.getExn

      // Verify processEventBatch correctly computed chain states
      switch EventHandlers.lastEmptyEventChains.contents {
      | Some(chains) => {
          // Chain 1 should be ready, chain 2 should not be ready
          Assert.equal(chains->Js.Dict.get("1")->Belt.Option.map(c => c.isReady), Some(true))
          Assert.equal(chains->Js.Dict.get("2")->Belt.Option.map(c => c.isReady), Some(false))
          Assert.equal(allChainsReady(chains), false)
        }
      | None => Assert.fail("Handler was not called")
      }
    })
  })
})
