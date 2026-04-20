open Vitest

let mockAddress0 = Envio.TestHelpers.Addresses.mockAddresses[0]->Option.getOrThrow

let chain = ChainMap.Chain.makeUnsafe(~chainId=1)

describe("HyperSyncSource - getSelectionConfig", () => {
  Async.it(
    "Correctly builds logs query field selection for empty block and transaction schemas",
    async t => {
      let selectionConfig = {
        dependsOnAddresses: true,
        eventConfigs: [(MockIndexer.evmEventConfig() :> Internal.eventConfig)],
      }->HyperSyncSource.getSelectionConfig(~chain)

      t.expect(selectionConfig).toEqual({
        fieldSelection: {
          block: [],
          log: [Address, Data, LogIndex, Topic0, Topic1, Topic2, Topic3],
          transaction: [],
        },
        getLogSelectionOrThrow: selectionConfig.getLogSelectionOrThrow,
        nonOptionalBlockFieldNames: [],
        nonOptionalTransactionFieldNames: [],
      })
      t.expect(
        selectionConfig.getLogSelectionOrThrow(~addressesByContractName=Dict.make()),
        ~message=`Shouldn't have a log selection without addresses.
        This is actually a wrong a behaviour and should throw in this case.
        If this happens it means we incorrectly created partitions for fetch state`,
      ).toEqual([])

      t.expect(
        selectionConfig.getLogSelectionOrThrow(
          ~addressesByContractName=Dict.fromArray([("ERC20", [mockAddress0])]),
        ),
        ~message=`Should have a log selection when an address is provided`,
      ).toEqual([
        {
          addresses: [mockAddress0],
          topicSelections: [
            {
              topic0: [MockIndexer.eventId->EvmTypes.Hex.fromStringUnsafe],
              topic1: [],
              topic2: [],
              topic3: [],
            },
          ],
        },
      ])

      t.expect(
        selectionConfig.getLogSelectionOrThrow(
          ~addressesByContractName=Dict.fromArray([("Bar", [mockAddress0])]),
        ),
        ~message=`Shouldn't have a log selection when contract name doesn't much the one in selection`,
      ).toEqual([])
    },
  )

  Async.it(
    "Correctly builds logs query field selection for complex block and transaction schemas",
    async t => {
      let selectionConfig = {
        dependsOnAddresses: true,
        eventConfigs: [
          (MockIndexer.evmEventConfig(
            ~blockFieldNames=([Hash, Number, Timestamp, Nonce]: array<Internal.evmBlockField>),
            ~transactionFieldNames=([Hash, GasPrice]: array<Internal.evmTransactionField>),
          ) :> Internal.eventConfig),
        ],
      }->HyperSyncSource.getSelectionConfig(~chain)

      t.expect(selectionConfig).toEqual({
        fieldSelection: {
          block: [Hash, Number, Timestamp, Nonce],
          transaction: [Hash, GasPrice],
          log: [Address, Data, LogIndex, Topic0, Topic1, Topic2, Topic3],
        },
        getLogSelectionOrThrow: selectionConfig.getLogSelectionOrThrow,
        nonOptionalBlockFieldNames: ["hash", "number", "timestamp"],
        nonOptionalTransactionFieldNames: ["hash"],
      })
    },
  )

  Async.it("Topics_only omits upstream address filtering for normal events", async t => {
    let selectionConfig = {
      dependsOnAddresses: true,
      eventConfigs: [(MockIndexer.evmEventConfig() :> Internal.eventConfig)],
    }->HyperSyncSource.getSelectionConfig(~chain, ~addressFilterMode=Config.TopicsOnly)

    t.expect(
      selectionConfig.getLogSelectionOrThrow(
        ~addressesByContractName=Dict.fromArray([("ERC20", [mockAddress0])]),
      ),
    ).toEqual([
      {
        addresses: [],
        topicSelections: [
          {
            topic0: [MockIndexer.eventId->EvmTypes.Hex.fromStringUnsafe],
            topic1: [],
            topic2: [],
            topic3: [],
          },
        ],
      },
    ])
  })

  Async.it("Combines field selection from multiple events on different contracts", async t => {
    let selectionConfig = {
      dependsOnAddresses: true,
      eventConfigs: [
        (MockIndexer.evmEventConfig(
          ~contractName="Foo",
          ~blockFieldNames=([Hash, Number, Timestamp]: array<Internal.evmBlockField>),
          ~transactionFieldNames=([Hash]: array<Internal.evmTransactionField>),
        ) :> Internal.eventConfig),
        (MockIndexer.evmEventConfig(
          ~contractName="Bar",
          ~blockFieldNames=([Nonce]: array<Internal.evmBlockField>),
          ~transactionFieldNames=([GasPrice]: array<Internal.evmTransactionField>),
        ) :> Internal.eventConfig),
      ],
    }->HyperSyncSource.getSelectionConfig(~chain)

    t.expect(selectionConfig).toEqual({
      fieldSelection: {
        block: [Hash, Number, Timestamp, Nonce],
        transaction: [Hash, GasPrice],
        log: [Address, Data, LogIndex, Topic0, Topic1, Topic2, Topic3],
      },
      getLogSelectionOrThrow: selectionConfig.getLogSelectionOrThrow,
      nonOptionalBlockFieldNames: ["hash", "number", "timestamp"],
      nonOptionalTransactionFieldNames: ["hash"],
    })
  })

  Async.it("Topic selection with two wildcard events", async t => {
    let selectionConfig = {
      dependsOnAddresses: false,
      eventConfigs: [
        (MockIndexer.evmEventConfig(
          ~id="wildcard event 1",
          ~isWildcard=true,
        ) :> Internal.eventConfig),
        (MockIndexer.evmEventConfig(
          ~id="wildcard event 2",
          ~isWildcard=true,
        ) :> Internal.eventConfig),
      ],
    }->HyperSyncSource.getSelectionConfig(~chain)

    t.expect(
      selectionConfig.getLogSelectionOrThrow(~addressesByContractName=Dict.make()),
      ~message=`Even though wildcard events belong to different contracts, they should be joined in to a single log selection`,
    ).toEqual([
      {
        addresses: [],
        topicSelections: [
          {
            topic0: [
              "wildcard event 1"->EvmTypes.Hex.fromStringUnsafe,
              "wildcard event 2"->EvmTypes.Hex.fromStringUnsafe,
            ],
            topic1: [],
            topic2: [],
            topic3: [],
          },
        ],
      },
    ])
  })

  Async.it(
    "Normal topic selection which depends on addresses & wildcard topic selection which depends on addresses",
    async t => {
      let selectionConfig = {
        dependsOnAddresses: false,
        eventConfigs: [
          (MockIndexer.evmEventConfig(~id="event 1") :> Internal.eventConfig),
          (MockIndexer.evmEventConfig(
            ~id="event 2",
            ~isWildcard=true,
            ~dependsOnAddresses=true,
          ) :> Internal.eventConfig),
        ],
      }->HyperSyncSource.getSelectionConfig(~chain)

      t.expect(
        selectionConfig.getLogSelectionOrThrow(
          ~addressesByContractName=Dict.fromArray([("ERC20", [mockAddress0])]),
        ),
      ).toEqual([
        {
          addresses: [mockAddress0],
          topicSelections: [
            {
              topic0: ["event 1"->EvmTypes.Hex.fromStringUnsafe],
              topic1: [],
              topic2: [],
              topic3: [],
            },
          ],
        },
        {
          addresses: [],
          topicSelections: [
            {
              topic0: ["event 2"->EvmTypes.Hex.fromStringUnsafe],
              topic1: [mockAddress0->Utils.magic],
              topic2: [],
              topic3: [],
            },
          ],
        },
      ])
    },
  )

  it("Topics_only rejects address-derived event filters", t => {
    try {
      let _ = {
        dependsOnAddresses: true,
        eventConfigs: [
          (MockIndexer.evmEventConfig(~filterByAddresses=true) :> Internal.eventConfig),
        ],
      }->HyperSyncSource.getSelectionConfig(~chain, ~addressFilterMode=Config.TopicsOnly)
      JsError.throwWithMessage("Should have thrown")
    } catch {
    | Source.GetItemsError(UnsupportedSelection({message})) =>
      t.expect(message).toBe(
        "HyperSync topics_only address filter mode does not support event filters derived from `chain.<Contract>.addresses`. Remove the address-based `where` filter or switch back to address_filter_mode: exact.",
      )
    | _ => JsError.throwWithMessage("Should have thrown UnsupportedSelection")
    }
  })
})
