open RescriptMocha
open Belt

let mockAddress0 = TestHelpers.Addresses.mockAddresses[0]->Option.getExn

module MockEvent = (
  T: {
    type block
    type transaction
    let blockSchema: S.t<block>
    let transactionSchema: S.t<transaction>
  },
): Types.Event => {
  let id = "0xcf16a92280c1bbb43f72d31126b724d508df2877835849e8744017ab36a9b47f_1"
  let sighash = "0xcf16a92280c1bbb43f72d31126b724d508df2877835849e8744017ab36a9b47f"
  let name = "EventWithoutFields"
  let contractName = "Foo"

  @genType
  type eventArgs = unit

  type block = T.block

  type transaction = T.transaction

  @genType
  type event = Internal.genericEvent<eventArgs, block, transaction>
  @genType
  type loader<'loaderReturn> = Internal.genericLoader<
    Internal.genericLoaderArgs<event, Types.loaderContext>,
    'loaderReturn,
  >
  @genType
  type handler<'loaderReturn> = Internal.genericHandler<
    Internal.genericHandlerArgs<event, Types.handlerContext, 'loaderReturn>,
  >
  @genType
  type contractRegister = Internal.genericContractRegister<
    Internal.genericContractRegisterArgs<event, Types.contractRegistrations>,
  >

  let paramsRawEventSchema = S.literal(%raw(`null`))->S.variant(_ => ())
  let blockSchema = T.blockSchema
  let transactionSchema = T.transactionSchema

  let convertHyperSyncEventArgs = (Utils.magic: HyperSyncClient.Decoder.decodedEvent => eventArgs)

  let handlerRegister: Types.HandlerTypes.Register.t = Types.HandlerTypes.Register.make(
    ~topic0=sighash->EvmTypes.Hex.fromStringUnsafe,
    ~contractName,
    ~eventName=name,
  )

  @genType
  type eventFilter = {}

  let getTopicSelection = eventFilters =>
    eventFilters
    ->Types.SingleOrMultiple.normalizeOrThrow
    ->Belt.Array.map(_eventFilter =>
      LogSelection.makeTopicSelection(
        ~topic0=[sighash->EvmTypes.Hex.fromStringUnsafe],
      )->Utils.unwrapResultExn
    )
}

// TODO: Add tests for RpcWorker
// TODO: Split changes into smaller PRs
// TODO: Handle rpc error to adjust suggested block range

let withConfig = (
  eventMod: module(Types.Event),
  eventConfig: Types.HandlerTypes.eventConfig<'a>,
) => {
  let module(Event) = eventMod
  Event.handlerRegister->Types.HandlerTypes.Register.setLoaderHandler(
    {
      loader: Types.HandlerTypes.Register.noopLoader,
      handler: _ => (),
      wildcard: ?eventConfig.wildcard,
      eventFilters: ?eventConfig.eventFilters,
      preRegisterDynamicContracts: ?eventConfig.preRegisterDynamicContracts,
    },
    ~getEventOptions=Types.makeGetEventOptions(
      eventMod->(
        Utils.magic: module(Types.Event) => module(Types.Event with
          type eventFilter = 'eventFilter
          and type eventArgs = 'eventArgs
        )
      ),
    ),
  )
  eventMod
}

describe("HyperSyncWorker - getSelectionConfig", () => {
  Async.it(
    "Correctly builds logs query field selection for empty block and transaction schemas",
    async () => {
      let selectionConfig = Normal({})->HyperSyncWorker.getSelectionConfig(
        ~contracts=[
          {
            name: "Foo",
            abi: %raw(`[]`),
            addresses: [],
            events: [
              module(
                MockEvent({
                  type transaction = {}
                  type block = {}
                  let blockSchema = S.object((_): block => {})
                  let transactionSchema = S.object((_): transaction => {})
                })
              ),
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
          ~isPreRegisteringDynamicContracts=false,
        ),
        [],
        ~message=`Shouldn't have a log selection without addresses.
        This is actually a wrong a behaviour and should throw in this case.
        If this happens it means we incorrectly created partitions for fetch state`,
      )
      Assert.deepEqual(
        selectionConfig.getLogSelectionOrThrow(
          ~contractAddressMapping=ContractAddressingMap.fromArray([(mockAddress0, "Foo")]),
          ~isPreRegisteringDynamicContracts=false,
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
          ~isPreRegisteringDynamicContracts=false,
        ),
        [],
        ~message=`Shouldn't have a log selection when contract name doesn't much the one in selection`,
      )
    },
  )

  Async.it(
    "Correctly builds logs query field selection for complex block and transaction schemas",
    async () => {
      let selectionConfig = Normal({})->HyperSyncWorker.getSelectionConfig(
        ~contracts=[
          {
            name: "Foo",
            abi: %raw(`[]`),
            addresses: [],
            events: [
              module(
                MockEvent({
                  type transaction = {}
                  type block = {}
                  let blockSchema = S.object(
                    (s): block => {
                      let _ = s.field("hash", S.string)
                      let _ = s.field("number", S.int)
                      let _ = s.field("timestamp", S.int)
                      let _ = s.field("nonce", S.null(BigInt.schema))
                      {}
                    },
                  )
                  let transactionSchema = S.object(
                    (s): transaction => {
                      let _ = s.field("hash", S.string)
                      let _ = s.field("gasPrice", S.null(S.string))
                      {}
                    },
                  )
                })
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
    let selectionConfig = Normal({})->HyperSyncWorker.getSelectionConfig(
      ~contracts=[
        {
          name: "Foo",
          abi: %raw(`[]`),
          addresses: [],
          events: [
            module(
              MockEvent({
                type transaction = {}
                type block = {}
                let blockSchema = S.object(
                  (s): block => {
                    let _ = s.field("hash", S.string)
                    let _ = s.field("number", S.int)
                    let _ = s.field("timestamp", S.int)
                    {}
                  },
                )
                let transactionSchema = S.object(
                  (s): transaction => {
                    let _ = s.field("hash", S.string)
                    {}
                  },
                )
              })
            ),
          ],
        },
        {
          name: "Bar",
          abi: %raw(`[]`),
          addresses: [],
          events: [
            module(
              MockEvent({
                type transaction = {}
                type block = {}
                let blockSchema = S.object(
                  (s): block => {
                    let _ = s.field("nonce", S.null(BigInt.schema))
                    {}
                  },
                )
                let transactionSchema = S.object(
                  (s): transaction => {
                    let _ = s.field("gasPrice", S.null(S.string))
                    {}
                  },
                )
              })
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
      let contracts: array<Config.contract> = [
        {
          name: "Foo",
          abi: %raw(`[]`),
          addresses: [],
          events: [
            module(
              MockEvent({
                type transaction = {}
                type block = {}
                let blockSchema = S.object(
                  (s): block => {
                    let _ = s.field("hash", S.string)
                    let _ = s.field("number", S.int)
                    let _ = s.field("timestamp", S.int)
                    {}
                  },
                )
                let transactionSchema = S.object(
                  (s): transaction => {
                    let _ = s.field("hash", S.string)
                    {}
                  },
                )
              })
            ),
          ],
        },
        {
          name: "Bar",
          abi: %raw(`[]`),
          addresses: [],
          events: [
            module(
              MockEvent({
                type transaction = {}
                type block = {}
                let blockSchema = S.object(
                  (s): block => {
                    let _ = s.field("nonce", S.null(BigInt.schema))
                    {}
                  },
                )
                let transactionSchema = S.object(
                  (s): transaction => {
                    let _ = s.field("gasPrice", S.null(S.string))
                    {}
                  },
                )
              })
            )->withConfig({wildcard: true}),
          ],
        },
        {
          name: "Baz",
          abi: %raw(`[]`),
          addresses: [],
          events: [
            module(
              MockEvent({
                type transaction = {}
                type block = {}
                let blockSchema = S.object(
                  (s): block => {
                    let _ = s.field("uncles", S.null(BigInt.schema))
                    {}
                  },
                )
                let transactionSchema = S.object(
                  (s): transaction => {
                    let _ = s.field("gasPrice", S.null(S.string))
                    {}
                  },
                )
              })
              // Eventhough this is a second wildcard event
              // it shouldn't be included in the field selection,
              // since it's not specified in the FetchState.selection
            )->withConfig({wildcard: true}),
          ],
        },
      ]

      let normalSelectionConfig = Normal({})->HyperSyncWorker.getSelectionConfig(~contracts)
      let wildcardSelectionConfig = Wildcard({
        eventConfigs: [
          {
            contractName: "Bar",
            eventId: "0xcf16a92280c1bbb43f72d31126b724d508df2877835849e8744017ab36a9b47f_1",
            isWildcard: true,
          },
        ],
      })->HyperSyncWorker.getSelectionConfig(~contracts)

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
          ~isPreRegisteringDynamicContracts=false,
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
          ~isPreRegisteringDynamicContracts=false,
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
})
