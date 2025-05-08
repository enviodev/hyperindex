open RescriptMocha
open Belt

let mockAddress0 = TestHelpers.Addresses.mockAddresses[0]->Option.getExn

let chain = ChainMap.Chain.makeUnsafe(~chainId=1)

describe("HyperSyncSource - getSelectionConfig", () => {
  Async.it(
    "Correctly builds logs query field selection for empty block and transaction schemas",
    async () => {
      let selectionConfig = {
        dependsOnAddresses: true,
        eventConfigs: [(Mock.evmEventConfig() :> Internal.eventConfig)],
      }->HyperSyncSource.getSelectionConfig(~chain)

      Assert.deepEqual(
        selectionConfig,
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
      Assert.deepEqual(
        selectionConfig.getLogSelectionOrThrow(~addressesByContractName=Js.Dict.empty()),
        [],
        ~message=`Shouldn't have a log selection without addresses.
        This is actually a wrong a behaviour and should throw in this case.
        If this happens it means we incorrectly created partitions for fetch state`,
      )

      Assert.deepEqual(
        selectionConfig.getLogSelectionOrThrow(
          ~addressesByContractName=Js.Dict.fromArray([("ERC20", [mockAddress0])]),
        ),
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
        ~message=`Should have a log selection when an address is provided`,
      )

      Assert.deepEqual(
        selectionConfig.getLogSelectionOrThrow(
          ~addressesByContractName=Js.Dict.fromArray([("Bar", [mockAddress0])]),
        ),
        [],
        ~message=`Shouldn't have a log selection when contract name doesn't much the one in selection`,
      )
    },
  )

  Async.it(
    "Correctly builds logs query field selection for complex block and transaction schemas",
    async () => {
      let selectionConfig = {
        dependsOnAddresses: true,
        eventConfigs: [
          (Mock.evmEventConfig(
            ~blockSchema=S.schema(
              s =>
                {
                  "hash": s.matches(S.string),
                  "number": s.matches(S.int),
                  "timestamp": s.matches(S.int),
                  "nonce": s.matches(S.null(BigInt.schema)),
                },
            ),
            ~transactionSchema=S.schema(
              s =>
                {
                  "hash": s.matches(S.string),
                  "gasPrice": s.matches(S.null(S.string)),
                },
            ),
          ) :> Internal.eventConfig),
        ],
      }->HyperSyncSource.getSelectionConfig(~chain)

      Assert.deepEqual(
        selectionConfig,
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

  Async.it("Combines field selection from multiple events on different contracts", async () => {
    let selectionConfig = {
      dependsOnAddresses: true,
      eventConfigs: [
        (Mock.evmEventConfig(
          ~contractName="Foo",
          ~blockSchema=S.schema(
            s =>
              {
                "hash": s.matches(S.string),
                "number": s.matches(S.int),
                "timestamp": s.matches(S.int),
              },
          ),
          ~transactionSchema=S.schema(
            s =>
              {
                "hash": s.matches(S.string),
              },
          ),
        ) :> Internal.eventConfig),
        (Mock.evmEventConfig(
          ~contractName="Bar",
          ~blockSchema=S.schema(
            s =>
              {
                "nonce": s.matches(S.null(BigInt.schema)),
              },
          ),
          ~transactionSchema=S.schema(
            s =>
              {
                "gasPrice": s.matches(S.null(S.string)),
              },
          ),
        ) :> Internal.eventConfig),
      ],
    }->HyperSyncSource.getSelectionConfig(~chain)

    Assert.deepEqual(
      selectionConfig,
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

  Async.it("Topic selection with two wildcard events", async () => {
    let selectionConfig = {
      dependsOnAddresses: false,
      eventConfigs: [
        (Mock.evmEventConfig(~id="wildcard event 1", ~isWildcard=true) :> Internal.eventConfig),
        (Mock.evmEventConfig(~id="wildcard event 2", ~isWildcard=true) :> Internal.eventConfig),
      ],
    }->HyperSyncSource.getSelectionConfig(~chain)

    Assert.deepEqual(
      selectionConfig.getLogSelectionOrThrow(~addressesByContractName=Js.Dict.empty()),
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
      ~message=`Even though wildcard events belong to different contracts, they should be joined in to a single log selection`,
    )
  })

  Async.it(
    "Normal topic selection which depends on addresses & wildcard topic selection which depends on addresses",
    async () => {
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

      Assert.deepEqual(
        selectionConfig.getLogSelectionOrThrow(
          ~addressesByContractName=Js.Dict.fromArray([("ERC20", [mockAddress0])]),
        ),
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
