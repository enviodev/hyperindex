module InMemoryStore = {
  let setEntity = (inMemoryStore, ~entityMod, entity) => {
    let inMemTable =
      inMemoryStore->InMemoryStore.getInMemTable(
        ~entityConfig=entityMod->Entities.entityModToInternal,
      )
    let entity = entity->(Utils.magic: 'a => Entities.internalEntity)
    inMemTable->InMemoryTable.Entity.set(
      Set(entity)->Types.mkEntityUpdate(
        ~eventIdentifier={
          chainId: 0,
          blockTimestamp: 0,
          blockNumber: 0,
          logIndex: 0,
        },
        ~entityId=entity->Entities.getEntityId,
      ),
      ~shouldSaveHistory=RegisterHandlers.getConfig()->Config.shouldSaveHistory(
        ~isInReorgThreshold=false,
      ),
    )
  }

  let make = (~entities=[]) => {
    let inMemoryStore = InMemoryStore.make()
    entities->Js.Array2.forEach(((entityMod, items)) => {
      items->Js.Array2.forEach(entity => {
        inMemoryStore->setEntity(~entityMod, entity)
      })
    })
    inMemoryStore
  }
}

module LoadLayer = {
  type loadEntitiesByIdsCall = {
    entityIds: array<string>,
    entityName: string,
  }
  type loadEntitiesByFieldCall = {
    entityName: string,
    fieldName: string,
    fieldValue: LoadLayer.fieldValue,
    fieldValueSchema: S.t<LoadLayer.fieldValue>,
    operator: TableIndices.Operator.t,
  }
  type t = {
    loadLayer: LoadLayer.t,
    loadEntitiesByIdsCalls: array<loadEntitiesByIdsCall>,
    loadEntitiesByFieldCalls: array<loadEntitiesByFieldCall>,
  }

  let make = () => {
    let loadEntitiesByIdsCalls = []
    let loadEntitiesByFieldCalls = []
    let loadLayer = LoadLayer.make(
      ~loadEntitiesByIds=async (entityIds, ~entityConfig) => {
        loadEntitiesByIdsCalls
        ->Js.Array2.push({
          entityIds,
          entityName: entityConfig.name,
        })
        ->ignore
        []
      },
      ~loadEntitiesByField=async (
        ~operator,
        ~entityConfig,
        ~fieldName,
        ~fieldValue,
        ~fieldValueSchema,
        ~logger as _=?,
      ) => {
        loadEntitiesByFieldCalls
        ->Js.Array2.push({
          operator,
          entityName: entityConfig.name,
          fieldName,
          fieldValue,
          fieldValueSchema,
        })
        ->ignore
        []
      },
    )

    {
      loadLayer,
      loadEntitiesByIdsCalls,
      loadEntitiesByFieldCalls,
    }
  }
}

@genType
let mockRawEventRow: TablesStatic.RawEvents.t = {
  chainId: 1,
  eventId: 1234567890n,
  contractName: "NftFactory",
  eventName: "SimpleNftCreated",
  blockNumber: 1000,
  logIndex: 10,
  transactionFields: S.reverseConvertToJsonOrThrow(
    {
      Types.Transaction.transactionIndex: 20,
      hash: "0x1234567890abcdef",
    },
    Types.Transaction.schema,
  ),
  srcAddress: "0x0123456789abcdef0123456789abcdef0123456"->Utils.magic,
  blockHash: "0x9876543210fedcba9876543210fedcba987654321",
  blockTimestamp: 1620720000,
  blockFields: %raw(`{}`),
  params: {
    "foo": "bar",
    "baz": 42,
  }->Utils.magic,
}

let eventId = "0xcf16a92280c1bbb43f72d31126b724d508df2877835849e8744017ab36a9b47f_1"

let evmEventConfig = (
  ~id=eventId,
  ~contractName="ERC20",
  ~blockSchema: option<S.t<'block>>=?,
  ~transactionSchema: option<S.t<'transaction>>=?,
  ~isWildcard=false,
  ~dependsOnAddresses=?,
  ~filterByAddresses=false,
): Internal.evmEventConfig => {
  {
    id,
    contractName,
    name: "EventWithoutFields",
    isWildcard,
    filterByAddresses,
    dependsOnAddresses: filterByAddresses ||
    dependsOnAddresses->Belt.Option.getWithDefault(!isWildcard),
    loader: None,
    handler: None,
    contractRegister: None,
    paramsRawEventSchema: S.literal(%raw(`null`))
    ->S.shape(_ => ())
    ->(Utils.magic: S.t<unit> => S.t<Internal.eventParams>),
    blockSchema: blockSchema
    ->Belt.Option.getWithDefault(S.object(_ => ())->Utils.magic)
    ->Utils.magic,
    transactionSchema: transactionSchema
    ->Belt.Option.getWithDefault(S.object(_ => ())->Utils.magic)
    ->Utils.magic,
    getEventFiltersOrThrow: _ =>
      switch dependsOnAddresses {
      | Some(true) =>
        Dynamic(
          addresses => [
            {
              topic0: [
                // This is a sighash in the original code
                id->EvmTypes.Hex.fromStringUnsafe,
              ],
              topic1: addresses->Utils.magic,
              topic2: [],
              topic3: [],
            },
          ],
        )
      | _ =>
        Static([
          {
            topic0: [
              // This is a sighash in the original code
              id->EvmTypes.Hex.fromStringUnsafe,
            ],
            topic1: [],
            topic2: [],
            topic3: [],
          },
        ])
      },
    convertHyperSyncEventArgs: _ => Js.Exn.raiseError("Not implemented"),
  }
}
