// A no-param EVM event registration, built the way `EventConfigBuilder` builds a
// real one. Tests that drive fetch state, address stores or sources need
// registrations without needing an ABI behind them.

let eventId = "0xcf16a92280c1bbb43f72d31126b724d508df2877835849e8744017ab36a9b47f_1"

let evmOnEventRegistration = (
  ~id=eventId,
  ~contractName="ERC20",
  ~blockFieldNames: array<Internal.evmBlockField>=[],
  ~transactionFieldNames: array<Internal.evmTransactionField>=[],
  ~isWildcard=false,
  ~dependsOnAddresses=?,
  ~filterByAddresses=false,
  ~startBlock: option<int>=?,
  ~eventFilters: option<array<Internal.resolvedTopicSelection>>=?,
  // Override the event's ABI when a test needs indexed params (so its logs
  // carry the topics its `where` filters on). Defaults to a no-param,
  // single-topic event. `topicCount` is derived from the indexed params the
  // same way production's `EventConfigBuilder.buildEvmEventConfig` does, so the
  // two can't drift.
  ~paramsMetadata: array<Internal.paramMeta>=[],
  ~topicCount=paramsMetadata->Array.reduce(1, (acc, p) => p.indexed ? acc + 1 : acc),
): Internal.evmOnEventRegistration => {
  let eventConfig: Internal.evmEventConfig = {
    id,
    contractName,
    name: "EventWithoutFields",
    paramsRawEventSchema: EventConfigBuilder.buildParamsSchema(paramsMetadata),
    simulateParamsSchema: EventConfigBuilder.buildSimulateParamsSchema(paramsMetadata),
    fieldSelection: Internal.makeFieldSelection(
      ~blockFields=Utils.Set.fromArray(blockFieldNames)->(
        Utils.magic: Utils.Set.t<Internal.evmBlockField> => Utils.Set.t<string>
      ),
      ~transactionFields=Utils.Set.fromArray(transactionFieldNames)->(
        Utils.magic: Utils.Set.t<Internal.evmTransactionField> => Utils.Set.t<string>
      ),
      ~blockMaskFn=Evm.eventBlockFieldMask,
      ~transactionMaskFn=Evm.eventTransactionFieldMask,
    ),
    sighash: id,
    topicCount,
    paramsMetadata,
  }
  {
    index: -1,
    eventConfig: (eventConfig :> Internal.eventConfig),
    isWildcard,
    filterByAddresses,
    dependsOnAddresses: filterByAddresses || dependsOnAddresses->Option.getOr(!isWildcard),
    addressFilterParamGroups: [],
    startBlock,
    handler: None,
    contractRegister: None,
    fieldSelection: eventConfig.fieldSelection,
    resolvedWhere: {
      topicSelections: switch eventFilters {
      | Some(topicSelections) => topicSelections
      | None => [
          {
            topic0: [
              // This is a sighash in the original code
              id->EvmTypes.Hex.fromStringUnsafe,
            ],
            topic1: switch dependsOnAddresses {
            | Some(true) => ContractAddresses({contractName: contractName})
            | _ => Values([])
            },
            topic2: Values([]),
            topic3: Values([]),
          },
        ]
      },
      startBlock: None,
    },
  }
}
