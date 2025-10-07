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
    it("should be Historical when chains have not reached end block", () => {
      // This test verifies the logic:
      // eventOrigin = if chainFetchers->allChainsEventsProcessedToEndblock { Live } else { Historical }

      let chainFetcher = {
        "committedProgressBlockNumber": 500,
        "fetchState": {
          "endBlock": Some(1000),
        },
      }->Utils.magic

      let chainFetchers = ChainMap.fromArrayUnsafe([(ChainMap.Chain.makeUnsafe(~chainId=1), chainFetcher)])
      let allProcessed = EventProcessing.allChainsEventsProcessedToEndblock(chainFetchers)

      // When not all chains processed to end block
      Assert.equal(allProcessed, false)
      // Then eventOrigin should be Historical
      let expectedOrigin: Internal.eventOrigin = Historical
      let actualOrigin: Internal.eventOrigin = if allProcessed {
        Live
      } else {
        Historical
      }
      Assert.equal(actualOrigin, expectedOrigin)
    })

    it("should be Live when all chains have reached end block", () => {
      let chainFetcher = {
        "committedProgressBlockNumber": 1000,
        "fetchState": {
          "endBlock": Some(1000),
        },
      }->Utils.magic

      let chainFetchers = ChainMap.fromArrayUnsafe([(ChainMap.Chain.makeUnsafe(~chainId=1), chainFetcher)])
      let allProcessed = EventProcessing.allChainsEventsProcessedToEndblock(chainFetchers)

      // When all chains processed to end block
      Assert.equal(allProcessed, true)
      // Then eventOrigin should be Live
      let expectedOrigin: Internal.eventOrigin = Live
      let actualOrigin: Internal.eventOrigin = if allProcessed {
        Live
      } else {
        Historical
      }
      Assert.equal(actualOrigin, expectedOrigin)
    })
  })
})
