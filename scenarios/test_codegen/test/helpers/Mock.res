module InMemoryStore = {
  let setEntity = (inMemoryStore, ~entityMod, entity) => {
    let inMemTable =
      inMemoryStore->InMemoryStore.getInMemTable(~entityMod=entityMod->Entities.entityModToInternal)
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
    entityMod: module(Entities.InternalEntity),
    logger?: Pino.t,
  }
  type loadEntitiesByFieldCall = {
    entityMod: module(Entities.InternalEntity),
    fieldName: string,
    fieldValue: LoadLayer.fieldValue,
    fieldValueSchema: S.t<LoadLayer.fieldValue>,
    logger?: Pino.t,
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
      ~loadEntitiesByIds=async (entityIds, ~entityMod, ~logger=?) => {
        loadEntitiesByIdsCalls
        ->Js.Array2.push({
          entityIds,
          entityMod,
          ?logger,
        })
        ->ignore
        []
      },
      ~makeLoadEntitiesByField=(~entityMod) => async (
        ~fieldName,
        ~fieldValue,
        ~fieldValueSchema,
        ~logger=?,
      ) => {
        loadEntitiesByFieldCalls
        ->Js.Array2.push({
          entityMod,
          fieldName,
          fieldValue,
          fieldValueSchema,
          ?logger,
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
  eventId: 1234567890->Belt.Int.toString,
  contractName: "NftFactory",
  eventName: "SimpleNftCreated",
  blockNumber: 1000,
  logIndex: 10,
  transactionFields: S.serializeOrRaiseWith(
    {
      Types.Transaction.transactionIndex: 20,
      hash: "0x1234567890abcdef",
    },
    Types.Transaction.schema,
  ),
  srcAddress: "0x0123456789abcdef0123456789abcdef0123456"->Utils.magic,
  blockHash: "0x9876543210fedcba9876543210fedcba987654321",
  blockTimestamp: 1620720000,
  blockFields: S.serializeOrRaiseWith(({}: Types.Block.selectableFields), Types.Block.schema),
  params: {
    "foo": "bar",
    "baz": 42,
  }->Utils.magic,
}
