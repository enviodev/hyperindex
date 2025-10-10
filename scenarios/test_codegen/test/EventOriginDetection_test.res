open RescriptMocha

describe("EventOrigin Detection Logic", () => {
  describe("allChainsEventsProcessedToEndblock", () => {
    it("should return true when all chains have reached their end block", () => {
      // Create mock chain fetchers that have all reached end block
      let chainFetcher1 = {
        "committedProgressBlockNumber": 1000,
        "fetchState": {
          "endBlock": Some(1000),
        },
      }->Utils.magic

      let chainFetcher2 = {
        "committedProgressBlockNumber": 2000,
        "fetchState": {
          "endBlock": Some(2000),
        },
      }->Utils.magic

      let chainFetchers =
        ChainMap.fromArrayUnsafe([
          (ChainMap.Chain.makeUnsafe(~chainId=1), chainFetcher1),
          (ChainMap.Chain.makeUnsafe(~chainId=2), chainFetcher2),
        ])

      let result = EventProcessing.allChainsEventsProcessedToEndblock(chainFetchers)
      Assert.equal(result, true)
    })

    it("should return false when at least one chain has not reached end block", () => {
      // Chain 1 has reached end block, but chain 2 has not
      let chainFetcher1 = {
        "committedProgressBlockNumber": 1000,
        "fetchState": {
          "endBlock": Some(1000),
        },
      }->Utils.magic

      let chainFetcher2 = {
        "committedProgressBlockNumber": 1500,
        "fetchState": {
          "endBlock": Some(2000), // Not yet reached
        },
      }->Utils.magic

      let chainFetchers =
        ChainMap.fromArrayUnsafe([
          (ChainMap.Chain.makeUnsafe(~chainId=1), chainFetcher1),
          (ChainMap.Chain.makeUnsafe(~chainId=2), chainFetcher2),
        ])

      let result = EventProcessing.allChainsEventsProcessedToEndblock(chainFetchers)
      Assert.equal(result, false)
    })

    it("should return false when a chain has no end block (live mode)", () => {
      // Chain with no end block set (continuous live indexing)
      let chainFetcher1 = {
        "committedProgressBlockNumber": 1000,
        "fetchState": {
          "endBlock": None, // Live mode, no end block
        },
      }->Utils.magic

      let chainFetchers = ChainMap.fromArrayUnsafe([(ChainMap.Chain.makeUnsafe(~chainId=1), chainFetcher1)])

      let result = EventProcessing.allChainsEventsProcessedToEndblock(chainFetchers)
      Assert.equal(result, false)
    })

    it("should return false when committedProgressBlockNumber is below endBlock", () => {
      let chainFetcher1 = {
        "committedProgressBlockNumber": 500,
        "fetchState": {
          "endBlock": Some(1000),
        },
      }->Utils.magic

      let chainFetchers = ChainMap.fromArrayUnsafe([(ChainMap.Chain.makeUnsafe(~chainId=1), chainFetcher1)])

      let result = EventProcessing.allChainsEventsProcessedToEndblock(chainFetchers)
      Assert.equal(result, false)
    })

    it("should return true when committedProgressBlockNumber exceeds endBlock", () => {
      // Progress can go beyond end block in some edge cases
      let chainFetcher1 = {
        "committedProgressBlockNumber": 1500,
        "fetchState": {
          "endBlock": Some(1000),
        },
      }->Utils.magic

      let chainFetchers = ChainMap.fromArrayUnsafe([(ChainMap.Chain.makeUnsafe(~chainId=1), chainFetcher1)])

      let result = EventProcessing.allChainsEventsProcessedToEndblock(chainFetchers)
      Assert.equal(result, true)
    })

    it("should handle empty chainFetchers map (edge case)", () => {
      let chainFetchers = ChainMap.fromArrayUnsafe([])

      let result = EventProcessing.allChainsEventsProcessedToEndblock(chainFetchers)
      // Array.every returns true for empty array
      Assert.equal(result, true)
    })

    it("should return false in multi-chain scenario when only some chains reached end", () => {
      let chainFetcher1 = {
        "committedProgressBlockNumber": 1000,
        "fetchState": {
          "endBlock": Some(1000), // Reached
        },
      }->Utils.magic

      let chainFetcher2 = {
        "committedProgressBlockNumber": 1999,
        "fetchState": {
          "endBlock": Some(2000), // Not reached (1 block away)
        },
      }->Utils.magic

      let chainFetcher3 = {
        "committedProgressBlockNumber": 3000,
        "fetchState": {
          "endBlock": Some(3000), // Reached
        },
      }->Utils.magic

      let chainFetchers =
        ChainMap.fromArrayUnsafe([
          (ChainMap.Chain.makeUnsafe(~chainId=1), chainFetcher1),
          (ChainMap.Chain.makeUnsafe(~chainId=2), chainFetcher2),
          (ChainMap.Chain.makeUnsafe(~chainId=3), chainFetcher3),
        ])

      let result = EventProcessing.allChainsEventsProcessedToEndblock(chainFetchers)
      Assert.equal(result, false)
    })

    it("should return true only when ALL chains in multi-chain scenario reached end", () => {
      let chainFetcher1 = {
        "committedProgressBlockNumber": 1000,
        "fetchState": {
          "endBlock": Some(1000),
        },
      }->Utils.magic

      let chainFetcher2 = {
        "committedProgressBlockNumber": 2000,
        "fetchState": {
          "endBlock": Some(2000),
        },
      }->Utils.magic

      let chainFetcher3 = {
        "committedProgressBlockNumber": 3000,
        "fetchState": {
          "endBlock": Some(3000),
        },
      }->Utils.magic

      let chainFetchers =
        ChainMap.fromArrayUnsafe([
          (ChainMap.Chain.makeUnsafe(~chainId=1), chainFetcher1),
          (ChainMap.Chain.makeUnsafe(~chainId=2), chainFetcher2),
          (ChainMap.Chain.makeUnsafe(~chainId=3), chainFetcher3),
        ])

      let result = EventProcessing.allChainsEventsProcessedToEndblock(chainFetchers)
      Assert.equal(result, true)
    })
  })

  describe("eventOrigin determination in processEventBatch", () => {
    // These tests actually invoke EventProcessing.processEventBatch and verify
    // that it correctly passes eventOrigin to handlers based on chainFetchers state

    Async.it("should pass Historical when chains have not reached end block", async () => {
      EventHandlers.lastEmptyEventOrigin := None

      // Setup: chain has NOT reached its end block (500 < 1000)
      let chainFetcher = {
        "committedProgressBlockNumber": 500,
        "fetchState": {"endBlock": Some(1000)},
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

      // Assert on the eventOrigin that processEventBatch passed to the handler
      switch EventHandlers.lastEmptyEventOrigin.contents {
      | Some(Historical) => Assert.ok(true)
      | Some(Live) => Assert.fail("Expected Historical but processEventBatch passed Live")
      | None => Assert.fail("Handler was not called - processEventBatch didn't execute handler")
      }
    })

    Async.it("should pass Live when all chains have reached end block", async () => {
      EventHandlers.lastEmptyEventOrigin := None

      // Setup: chain HAS reached its end block (1000 >= 1000)
      let chainFetcher = {
        "committedProgressBlockNumber": 1000,
        "fetchState": {"endBlock": Some(1000)},
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
      switch EventHandlers.lastEmptyEventOrigin.contents {
      | Some(Live) => Assert.ok(true)
      | Some(Historical) => Assert.fail("Expected Live but processEventBatch passed Historical")
      | None => Assert.fail("Handler was not called")
      }
    })

    Async.it("should pass Historical in multi-chain when not all reached end", async () => {
      EventHandlers.lastEmptyEventOrigin := None

      // Setup: chain 1 reached end, chain 2 has not
      let chainFetcher1 = {
        "committedProgressBlockNumber": 1000,
        "fetchState": {"endBlock": Some(1000)},
      }->Utils.magic
      let chainFetcher2 = {
        "committedProgressBlockNumber": 1500,
        "fetchState": {"endBlock": Some(2000)},
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

      // Verify processEventBatch correctly determined Historical
      switch EventHandlers.lastEmptyEventOrigin.contents {
      | Some(Historical) => Assert.ok(true)
      | Some(Live) => Assert.fail("Expected Historical but got Live")
      | None => Assert.fail("Handler was not called")
      }
    })
  })
})
