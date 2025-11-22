open Belt
open RescriptMocha

describe("OnlyWhenReady Event Filtering", () => {
  let chainId = 1337
  let mockAddress = TestHelpers.Addresses.mockAddresses[0]->Option.getExn

  let makeChainConfig = (
    ~eventConfigs: array<Internal.eventConfig>,
    ~startBlock=0,
  ): Config.chain => {
    {
      id: chainId,
      startBlock,
      sources: [
        Config.HyperSync({
          endpointUrl: "http://localhost:8080",
        }),
      ],
      maxReorgDepth: 100,
      contracts: [
        {
          name: "TestContract",
          abi: [],
          addresses: [mockAddress],
          events: eventConfigs,
          startBlock: None,
        },
      ],
    }
  }

  let makeConfig = (~enableRawEvents=false, ~chains=[]): Config.t => {
    Config.make(
      ~shouldRollbackOnReorg=true,
      ~shouldSaveFullHistory=false,
      ~chains,
      ~enableRawEvents,
      ~preloadHandlers=false,
      ~ecosystem=Platform.Evm,
      ~batchSize=5000,
      ~lowercaseAddresses=false,
      ~multichain=Config.Unordered,
      ~shouldUseHypersyncClientDecoder=true,
      ~maxAddrInPartition=100,
    )
  }

  let makeRegistrations = (): EventRegister.registrations => {
    {
      onBlockByChainId: Js.Dict.empty(),
    }
  }

  describe("ChainFetcher event filtering based on onlyWhenReady", () => {
    it("should filter out onlyWhenReady events when chain is not ready", () => {
      let regularEvent = (Mock.evmEventConfig(
        ~id="regular",
        ~contractName="TestContract",
        ~onlyWhenReady=false,
      ) :> Internal.eventConfig)

      let onlyWhenReadyEvent = (Mock.evmEventConfig(
        ~id="onlyWhenReady",
        ~contractName="TestContract",
        ~onlyWhenReady=true,
      ) :> Internal.eventConfig)

      let chainConfig = makeChainConfig(~eventConfigs=[regularEvent, onlyWhenReadyEvent])
      let config = makeConfig(~chains=[chainConfig])
      let registrations = makeRegistrations()

      // Chain is NOT ready (timestampCaughtUpToHeadOrEndblock = None)
      let chainFetcher = ChainFetcher.make(
        ~chainConfig,
        ~config,
        ~registrations,
        ~dynamicContracts=[],
        ~startBlock=0,
        ~endBlock=None,
        ~firstEventBlockNumber=None,
        ~progressBlockNumber=-1,
        ~timestampCaughtUpToHeadOrEndblock=None, // Chain not ready
        ~numEventsProcessed=0,
        ~numBatchesFetched=0,
        ~targetBufferSize=5000,
        ~logger=Logging.logger,
        ~isInReorgThreshold=false,
        ~reorgCheckpoints=[],
        ~maxReorgDepth=100,
      )

      // Only the regular event should be included
      let eventConfigs = chainFetcher.fetchState.eventConfigs
      Assert.deep_equal(eventConfigs->Array.length, 1)
      Assert.deep_equal(eventConfigs[0]->Option.getExn.id, "regular")
    })

    it("should include onlyWhenReady events when chain is ready", () => {
      let regularEvent = (Mock.evmEventConfig(
        ~id="regular",
        ~contractName="TestContract",
        ~onlyWhenReady=false,
      ) :> Internal.eventConfig)

      let onlyWhenReadyEvent = (Mock.evmEventConfig(
        ~id="onlyWhenReady",
        ~contractName="TestContract",
        ~onlyWhenReady=true,
      ) :> Internal.eventConfig)

      let chainConfig = makeChainConfig(~eventConfigs=[regularEvent, onlyWhenReadyEvent])
      let config = makeConfig(~chains=[chainConfig])
      let registrations = makeRegistrations()

      // Chain IS ready (timestampCaughtUpToHeadOrEndblock = Some)
      let chainFetcher = ChainFetcher.make(
        ~chainConfig,
        ~config,
        ~registrations,
        ~dynamicContracts=[],
        ~startBlock=0,
        ~endBlock=None,
        ~firstEventBlockNumber=None,
        ~progressBlockNumber=-1,
        ~timestampCaughtUpToHeadOrEndblock=Some(Js.Date.make()), // Chain ready
        ~numEventsProcessed=0,
        ~numBatchesFetched=0,
        ~targetBufferSize=5000,
        ~logger=Logging.logger,
        ~isInReorgThreshold=false,
        ~reorgCheckpoints=[],
        ~maxReorgDepth=100,
      )

      // Both events should be included
      let eventConfigs = chainFetcher.fetchState.eventConfigs
      Assert.deep_equal(eventConfigs->Array.length, 2)

      // Verify both event IDs are present
      let eventIds = eventConfigs->Array.map(ec => ec.id)->Array.sort((a, b) => {
        if a < b { -1 } else if a > b { 1 } else { 0 }
      })
      Assert.deep_equal(eventIds, ["onlyWhenReady", "regular"])
    })

    it("should always include regular events regardless of ready state", () => {
      let regularEvent1 = (Mock.evmEventConfig(
        ~id="regular1",
        ~contractName="TestContract",
        ~onlyWhenReady=false,
      ) :> Internal.eventConfig)

      let regularEvent2 = (Mock.evmEventConfig(
        ~id="regular2",
        ~contractName="TestContract",
        ~onlyWhenReady=false,
      ) :> Internal.eventConfig)

      let chainConfig = makeChainConfig(~eventConfigs=[regularEvent1, regularEvent2])
      let config = makeConfig(~chains=[chainConfig])
      let registrations = makeRegistrations()

      // Test with chain NOT ready
      let chainFetcherNotReady = ChainFetcher.make(
        ~chainConfig,
        ~config,
        ~registrations,
        ~dynamicContracts=[],
        ~startBlock=0,
        ~endBlock=None,
        ~firstEventBlockNumber=None,
        ~progressBlockNumber=-1,
        ~timestampCaughtUpToHeadOrEndblock=None,
        ~numEventsProcessed=0,
        ~numBatchesFetched=0,
        ~targetBufferSize=5000,
        ~logger=Logging.logger,
        ~isInReorgThreshold=false,
        ~reorgCheckpoints=[],
        ~maxReorgDepth=100,
      )

      Assert.deep_equal(chainFetcherNotReady.fetchState.eventConfigs->Array.length, 2)

      // Test with chain ready
      let chainFetcherReady = ChainFetcher.make(
        ~chainConfig,
        ~config,
        ~registrations,
        ~dynamicContracts=[],
        ~startBlock=0,
        ~endBlock=None,
        ~firstEventBlockNumber=None,
        ~progressBlockNumber=-1,
        ~timestampCaughtUpToHeadOrEndblock=Some(Js.Date.make()),
        ~numEventsProcessed=0,
        ~numBatchesFetched=0,
        ~targetBufferSize=5000,
        ~logger=Logging.logger,
        ~isInReorgThreshold=false,
        ~reorgCheckpoints=[],
        ~maxReorgDepth=100,
      )

      Assert.deep_equal(chainFetcherReady.fetchState.eventConfigs->Array.length, 2)
    })

    it("should work correctly with enableRawEvents mode", () => {
      let onlyWhenReadyEvent = (Mock.evmEventConfig(
        ~id="onlyWhenReady",
        ~contractName="TestContract",
        ~onlyWhenReady=true,
      ) :> Internal.eventConfig)

      let chainConfig = makeChainConfig(~eventConfigs=[onlyWhenReadyEvent])
      let config = makeConfig(~enableRawEvents=true, ~chains=[chainConfig])
      let registrations = makeRegistrations()

      // With raw events enabled, events should be included even if not ready
      let chainFetcher = ChainFetcher.make(
        ~chainConfig,
        ~config,
        ~registrations,
        ~dynamicContracts=[],
        ~startBlock=0,
        ~endBlock=None,
        ~firstEventBlockNumber=None,
        ~progressBlockNumber=-1,
        ~timestampCaughtUpToHeadOrEndblock=None, // Not ready
        ~numEventsProcessed=0,
        ~numBatchesFetched=0,
        ~targetBufferSize=5000,
        ~logger=Logging.logger,
        ~isInReorgThreshold=false,
        ~reorgCheckpoints=[],
        ~maxReorgDepth=100,
      )

      // Event should be included because raw events mode is enabled
      Assert.deep_equal(chainFetcher.fetchState.eventConfigs->Array.length, 1)
    })
  })
})
