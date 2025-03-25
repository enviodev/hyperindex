open RescriptMocha
open Belt

let mockAddress0 = TestHelpers.Addresses.mockAddresses[0]->Option.getExn

let chain = ChainMap.Chain.makeUnsafe(~chainId=1)
let eventId = "0xcf16a92280c1bbb43f72d31126b724d508df2877835849e8744017ab36a9b47f_1"

let mockEventConfig = (
  ~id=eventId,
  ~blockSchema,
  ~transactionSchema,
  ~isWildcard=false,
): Internal.evmEventConfig => {
  id,
  contractName: "Foo",
  name: "EventWithoutFields",
  isWildcard,
  preRegisterDynamicContracts: false,
  loader: None,
  handler: None,
  contractRegister: None,
  paramsRawEventSchema: S.literal(%raw(`null`))
  ->S.to(_ => ())
  ->(Utils.magic: S.t<unit> => S.t<Internal.eventParams>),
  blockSchema: blockSchema->(Utils.magic: S.t<'block> => S.t<Internal.eventBlock>),
  transactionSchema: transactionSchema->(
    Utils.magic: S.t<'transaction> => S.t<Internal.eventTransaction>
  ),
  getTopicSelectionsOrThrow: (~chain as _) => Js.Exn.raiseError("Not implemented"),
  convertHyperSyncEventArgs: _ => Js.Exn.raiseError("Not implemented"),
}

describe("HyperSyncSource - getSelectionConfig", () => {
  Async.it(
    "Correctly builds logs query field selection for empty block and transaction schemas",
    async () => {
      let selectionConfig = {
        isWildcard: false,
        eventConfigs: [
          {
            contractName: "Foo",
            eventId,
            isWildcard: false,
          },
        ],
      }->HyperSyncSource.getSelectionConfig(
        ~chain,
        ~contracts=[
          {
            name: "Foo",
            abi: %raw(`[]`),
            events: [
              mockEventConfig(~blockSchema=S.object(_ => ()), ~transactionSchema=S.object(_ => ())),
            ],
          },
        ],
      )

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
        selectionConfig.getLogSelectionOrThrow(
          ~contractAddressMapping=ContractAddressingMap.make(),
        ),
        [],
        ~message=`Shouldn't have a log selection without addresses.
        This is actually a wrong a behaviour and should throw in this case.
        If this happens it means we incorrectly created partitions for fetch state`,
      )
      Assert.deepEqual(
        selectionConfig.getLogSelectionOrThrow(
          ~contractAddressMapping=ContractAddressingMap.fromArray([(mockAddress0, "Foo")]),
        ),
        [
          {
            addresses: [mockAddress0],
            topicSelections: [
              {
                topic0: [
                  "0xcf16a92280c1bbb43f72d31126b724d508df2877835849e8744017ab36a9b47f"->EvmTypes.Hex.fromStringUnsafe,
                ],
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
          ~contractAddressMapping=ContractAddressingMap.fromArray([(mockAddress0, "Bar")]),
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
        isWildcard: false,
        eventConfigs: [
          {
            contractName: "Foo",
            eventId,
            isWildcard: false,
          },
        ],
      }->HyperSyncSource.getSelectionConfig(
        ~chain,
        ~contracts=[
          {
            name: "Foo",
            abi: %raw(`[]`),
            events: [
              mockEventConfig(
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
              ),
            ],
          },
        ],
      )

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

  Async.it("Combines field selection from multiple events", async () => {
    let selectionConfig = {
      isWildcard: false,
      eventConfigs: [
        {
          contractName: "Foo",
          eventId,
          isWildcard: false,
        },
        {
          contractName: "Bar",
          eventId,
          isWildcard: false,
        },
      ],
    }->HyperSyncSource.getSelectionConfig(
      ~chain,
      ~contracts=[
        {
          name: "Foo",
          abi: %raw(`[]`),
          events: [
            mockEventConfig(
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
            ),
          ],
        },
        {
          name: "Bar",
          abi: %raw(`[]`),
          events: [
            mockEventConfig(
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
            ),
          ],
        },
      ],
    )

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

  Async.it(
    "Doesn't include events not specified in the selection to the selection config",
    async () => {
      let contracts: array<Internal.evmContractConfig> = [
        {
          name: "Foo",
          abi: %raw(`[]`),
          events: [
            mockEventConfig(
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
            ),
          ],
        },
        {
          name: "Bar",
          abi: %raw(`[]`),
          events: [
            mockEventConfig(
              ~isWildcard=true,
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
            ),
          ],
        },
        {
          name: "Baz",
          abi: %raw(`[]`),
          events: [
            mockEventConfig(
              // Eventhough this is a second wildcard event
              // it shouldn't be included in the field selection,
              // since it's not specified in the FetchState.selection
              ~isWildcard=true,
              ~blockSchema=S.schema(
                s =>
                  {
                    "uncles": s.matches(S.null(BigInt.schema)),
                  },
              ),
              ~transactionSchema=S.schema(
                s =>
                  {
                    "gasPrice": s.matches(S.null(S.string)),
                  },
              ),
            ),
          ],
        },
      ]

      let normalSelectionConfig = {
        isWildcard: false,
        eventConfigs: [
          {
            contractName: "Foo",
            eventId,
            isWildcard: false,
          },
        ],
      }->HyperSyncSource.getSelectionConfig(~chain, ~contracts)
      let wildcardSelectionConfig = {
        isWildcard: true,
        eventConfigs: [
          {
            contractName: "Bar",
            eventId,
            isWildcard: true,
          },
        ],
      }->HyperSyncSource.getSelectionConfig(~chain, ~contracts)

      Assert.deepEqual(
        normalSelectionConfig,
        {
          fieldSelection: {
            block: [Hash, Number, Timestamp],
            log: [Address, Data, LogIndex, Topic0, Topic1, Topic2, Topic3],
            transaction: [Hash],
          },
          getLogSelectionOrThrow: normalSelectionConfig.getLogSelectionOrThrow,
          nonOptionalBlockFieldNames: ["hash", "number", "timestamp"],
          nonOptionalTransactionFieldNames: ["hash"],
        },
        ~message=`Should only include fields from the non-wildcard event`,
      )
      Assert.deepEqual(
        wildcardSelectionConfig,
        {
          fieldSelection: {
            block: [Nonce],
            log: [Address, Data, LogIndex, Topic0, Topic1, Topic2, Topic3],
            transaction: [GasPrice],
          },
          getLogSelectionOrThrow: wildcardSelectionConfig.getLogSelectionOrThrow,
          nonOptionalBlockFieldNames: [],
          nonOptionalTransactionFieldNames: [],
        },
        ~message=`Should only include fields from the wildcard event`,
      )
      Assert.deepEqual(
        normalSelectionConfig.getLogSelectionOrThrow(
          ~contractAddressMapping=ContractAddressingMap.fromArray([(mockAddress0, "Foo")]),
        ),
        [
          {
            addresses: [mockAddress0],
            topicSelections: [
              {
                topic0: [
                  "0xcf16a92280c1bbb43f72d31126b724d508df2877835849e8744017ab36a9b47f"->EvmTypes.Hex.fromStringUnsafe,
                ],
                topic1: [],
                topic2: [],
                topic3: [],
              },
            ],
          },
        ],
        ~message=`Should have a log selection for normal event`,
      )
      Assert.deepEqual(
        wildcardSelectionConfig.getLogSelectionOrThrow(
          ~contractAddressMapping=ContractAddressingMap.make(),
        ),
        [
          {
            addresses: [],
            topicSelections: [
              {
                topic0: [
                  "0xcf16a92280c1bbb43f72d31126b724d508df2877835849e8744017ab36a9b47f"->EvmTypes.Hex.fromStringUnsafe,
                ],
                topic1: [],
                topic2: [],
                topic3: [],
              },
            ],
          },
        ],
        ~message=`Should have a log selection for wildcard event without addresses`,
      )
    },
  )

  Async.it("Topic selection with two wildcard events", async () => {
    let contracts: array<Internal.evmContractConfig> = [
      {
        name: "Bar",
        abi: %raw(`[]`),
        events: [
          mockEventConfig(
            ~id="wildcard event 1",
            ~isWildcard=true,
            ~blockSchema=S.schema(_ => ()),
            ~transactionSchema=S.schema(_ => ()),
          ),
        ],
      },
      {
        name: "Baz",
        abi: %raw(`[]`),
        events: [
          mockEventConfig(
            ~id="wildcard event 2",
            ~isWildcard=true,
            ~blockSchema=S.schema(_ => ()),
            ~transactionSchema=S.schema(_ => ()),
          ),
        ],
      },
    ]

    let selectionConfig = {
      isWildcard: true,
      eventConfigs: [
        {
          contractName: "Bar",
          eventId,
          isWildcard: true,
        },
        {
          contractName: "Baz",
          eventId,
          isWildcard: true,
        },
      ],
    }->HyperSyncSource.getSelectionConfig(~chain, ~contracts)

    Assert.deepEqual(
      selectionConfig.getLogSelectionOrThrow(~contractAddressMapping=ContractAddressingMap.make()),
      [
        {
          addresses: [],
          topicSelections: [
            {
              topic0: [
                "topic0 - wildcard event 1"->EvmTypes.Hex.fromStringUnsafe,
                "topic0 - wildcard event 2"->EvmTypes.Hex.fromStringUnsafe,
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
})
