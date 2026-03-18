open Vitest
open Belt

let mockAddress0 = TestHelpers.Addresses.mockAddresses[0]->Option.getExn

let chain = ChainMap.Chain.makeUnsafe(~chainId=1)

describe("HyperSyncSource - getSelectionConfig", () => {
  Async.it(
    "Correctly builds logs query field selection for empty block and transaction schemas",
    async t => {
      let selectionConfig = {
        dependsOnAddresses: true,
        eventConfigs: [(Mock.evmEventConfig() :> Internal.eventConfig)],
      }->HyperSyncSource.getSelectionConfig(~chain)

      t.expect(
        selectionConfig,
      ).toEqual(
        {
          fieldSelection: {
            block: [],
            log: [Address, Data, LogIndex, Topic0, Topic1, Topic2, Topic3],
            transaction: [],
          },
          getLogSelectionOrThrow: selectionConfig.getLogSelectionOrThrow,
          nonOptionalBlockFieldNames: [],
          nonOptionalTransactionFieldNames: [],
        },
      )
      t.expect(
        selectionConfig.getLogSelectionOrThrow(~addressesByContractName=Js.Dict.empty()),
        ~message=`Shouldn't have a log selection without addresses.
        This is actually a wrong a behaviour and should throw in this case.
        If this happens it means we incorrectly created partitions for fetch state`,
      ).toEqual(
        [],
      )

      t.expect(
        selectionConfig.getLogSelectionOrThrow(
          ~addressesByContractName=Js.Dict.fromArray([("ERC20", [mockAddress0])]),
        ),
        ~message=`Should have a log selection when an address is provided`,
      ).toEqual(
        [
          {
            addresses: [mockAddress0],
            topicSelections: [
              {
                topic0: [Mock.eventId->EvmTypes.Hex.fromStringUnsafe],
                topic1: [],
                topic2: [],
                topic3: [],
              },
            ],
          },
        ],
      )

      t.expect(
        selectionConfig.getLogSelectionOrThrow(
          ~addressesByContractName=Js.Dict.fromArray([("Bar", [mockAddress0])]),
        ),
        ~message=`Shouldn't have a log selection when contract name doesn't much the one in selection`,
      ).toEqual(
        [],
      )
    },
  )

  Async.it(
    "Correctly builds logs query field selection for complex block and transaction schemas",
    async t => {
      let selectionConfig = {
        dependsOnAddresses: true,
        eventConfigs: [
          (Mock.evmEventConfig(
            ~blockFieldNames=([Hash, Number, Timestamp, Nonce]: array<Internal.evmBlockField>),
            ~transactionFieldNames=([Hash, GasPrice]: array<Internal.evmTransactionField>),
          ) :> Internal.eventConfig),
        ],
      }->HyperSyncSource.getSelectionConfig(~chain)

      t.expect(
        selectionConfig,
      ).toEqual(
        {
          fieldSelection: {
            block: [Hash, Number, Timestamp, Nonce],
            transaction: [Hash, GasPrice],
            log: [Address, Data, LogIndex, Topic0, Topic1, Topic2, Topic3],
          },
          getLogSelectionOrThrow: selectionConfig.getLogSelectionOrThrow,
          nonOptionalBlockFieldNames: ["hash", "number", "timestamp"],
          nonOptionalTransactionFieldNames: ["hash"],
        },
      )
    },
  )

  Async.it("Combines field selection from multiple events on different contracts", async t => {
    let selectionConfig = {
      dependsOnAddresses: true,
      eventConfigs: [
        (Mock.evmEventConfig(
          ~contractName="Foo",
          ~blockFieldNames=([Hash, Number, Timestamp]: array<Internal.evmBlockField>),
          ~transactionFieldNames=([Hash]: array<Internal.evmTransactionField>),
        ) :> Internal.eventConfig),
        (Mock.evmEventConfig(
          ~contractName="Bar",
          ~blockFieldNames=([Nonce]: array<Internal.evmBlockField>),
          ~transactionFieldNames=([GasPrice]: array<Internal.evmTransactionField>),
        ) :> Internal.eventConfig),
      ],
    }->HyperSyncSource.getSelectionConfig(~chain)

    t.expect(
      selectionConfig,
    ).toEqual(
      {
        fieldSelection: {
          block: [Hash, Number, Timestamp, Nonce],
          transaction: [Hash, GasPrice],
          log: [Address, Data, LogIndex, Topic0, Topic1, Topic2, Topic3],
        },
        getLogSelectionOrThrow: selectionConfig.getLogSelectionOrThrow,
        nonOptionalBlockFieldNames: ["hash", "number", "timestamp"],
        nonOptionalTransactionFieldNames: ["hash"],
      },
    )
  })

  Async.it("Topic selection with two wildcard events", async t => {
    let selectionConfig = {
      dependsOnAddresses: false,
      eventConfigs: [
        (Mock.evmEventConfig(~id="wildcard event 1", ~isWildcard=true) :> Internal.eventConfig),
        (Mock.evmEventConfig(~id="wildcard event 2", ~isWildcard=true) :> Internal.eventConfig),
      ],
    }->HyperSyncSource.getSelectionConfig(~chain)

    t.expect(
      selectionConfig.getLogSelectionOrThrow(~addressesByContractName=Js.Dict.empty()),
      ~message=`Even though wildcard events belong to different contracts, they should be joined in to a single log selection`,
    ).toEqual(
      [
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
      ],
    )
  })

  Async.it(
    "Normal topic selection which depends on addresses & wildcard topic selection which depends on addresses",
    async t => {
      let selectionConfig = {
        dependsOnAddresses: false,
        eventConfigs: [
          (Mock.evmEventConfig(~id="event 1") :> Internal.eventConfig),
          (Mock.evmEventConfig(
            ~id="event 2",
            ~isWildcard=true,
            ~dependsOnAddresses=true,
          ) :> Internal.eventConfig),
        ],
      }->HyperSyncSource.getSelectionConfig(~chain)

      t.expect(
        selectionConfig.getLogSelectionOrThrow(
          ~addressesByContractName=Js.Dict.fromArray([("ERC20", [mockAddress0])]),
        ),
      ).toEqual(
        [
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
        ],
      )
    },
  )
})
