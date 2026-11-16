// Turns the rows an `EventStore` hands out back into the items handlers
// receive, with each source's own item conversion.

// What rebuilding an item from its row needs: the chain's registrations, by
// the index rows carry.
type context = {
  chainId: ChainId.t,
  onEventRegistrations: array<Internal.onEventRegistration>,
  onBlockRegistrations: array<Internal.onBlockRegistration>,
}

@get_index external numberAt: (array<unknown>, int) => float = ""
@get_index external valueAt: (array<unknown>, int) => 'a = ""

%%private(
  let paramsByRegistration = (rows: EventStore.storedRows, ~buffers, ~cursor) => {
    let byRegistration = []
    rows.params->Array.forEach(({registrationIndex, shape}) => {
      let columns = Reading.columns(
        ~buffers,
        ~cursor,
        ~kinds=shape.kinds,
        ~elementKinds=shape.elementKinds,
        ~rows=shape.rows,
      )
      // A nested param travels as a tape, which the column points at, so it
      // goes in before the objects are built and keeps their shape stable.
      shape.kinds->Array.forEachWithIndex((kind, index) =>
        if kind === Reading.Tape {
          columns->Array.setUnsafe(
            index,
            columns
            ->Array.getUnsafe(index)
            ->Array.map(
              position => rows.tapes->Array.getUnsafe(position->(Utils.magic: unknown => int)),
            ),
          )
        }
      )
      byRegistration->Array.setUnsafe(
        registrationIndex,
        columns->Reading.objects(~names=shape.names, ~rows=shape.rows),
      )
    })
    byRegistration
  }
)

// Every row as an item. A JS-built row gets its registration back from
// `jsItemRegistration`, given the item's kind (0 for an event) and the index
// it was stored under.
let build = (
  rows: EventStore.storedRows,
  ~context: context,
  ~jsItemRegistration: (~kind: int, ~index: int) => unknown,
): array<Internal.item> =>
  rows->EventStore.read(buffers => {
    let cursor = ref(0)
    let columns = Reading.columns(
      ~buffers,
      ~cursor,
      ~kinds=rows.items.kinds,
      ~elementKinds=rows.items.elementKinds,
      ~rows=rows.items.rows,
    )
    // In the order `ITEM_COLUMNS` in `event_store.rs` lays them out.
    let column = Array.getUnsafe(columns, ...)
    let formats = column(0)
    let blockNumbers = column(1)
    let logIndexes = column(2)
    let transactionIndexes = column(3)
    let registrationIndexes = column(4)
    let srcAddresses = column(5)
    let skipped = column(6)
    let paramsRows = column(7)
    let tapePositions = column(8)
    let params = rows->paramsByRegistration(~buffers, ~cursor)
    let tapeAt = row => rows.tapes->Array.getUnsafe(tapePositions->numberAt(row)->Float.toInt)
    Array.fromInitializer(~length=rows.items.rows, row => {
      let registrationIndex = registrationIndexes->numberAt(row)->Float.toInt
      switch formats->numberAt(row)->Float.toInt->(Utils.magic: int => EventStore.format) {
      | EvmLog =>
        let item: EvmEventItem.t = {
          logIndex: logIndexes->numberAt(row)->Float.toInt,
          srcAddress: srcAddresses->valueAt(row),
          blockNumber: blockNumbers->numberAt(row)->Float.toInt,
          transactionIndex: transactionIndexes->numberAt(row)->Float.toInt,
          onEventRegistrationIndex: registrationIndex,
          params: params
          ->Array.getUnsafe(registrationIndex)
          ->Array.getUnsafe(paramsRows->numberAt(row)->Float.toInt)
          ->(Utils.magic: dict<unknown> => Internal.eventParams),
        }
        item->EvmEventItem.toInternalItem(
          ~onEventRegistration=context.onEventRegistrations
          ->Array.getUnsafe(registrationIndex)
          ->(Utils.magic: Internal.onEventRegistration => Internal.evmOnEventRegistration),
          ~chainId=context.chainId,
        )
      | Block =>
        let item: BlockItem.t = {
          blockNumber: blockNumbers->numberAt(row)->Float.toInt,
          onBlockRegistrationIndex: registrationIndex,
          skipped: skipped->valueAt(row),
        }
        item->BlockItem.toInternalItem(~onBlockRegistrations=context.onBlockRegistrations)
      | FuelReceipt =>
        let item = tapeAt(row)->(Utils.magic: unknown => FuelHyperSyncClient.EventItems.item)
        item->FuelEventItem.toInternalItem(
          ~onEventRegistration=context.onEventRegistrations->Array.getUnsafe(registrationIndex),
          ~chainId=context.chainId,
        )
      | SvmInstruction =>
        let item = tapeAt(row)->(Utils.magic: unknown => SvmHyperSyncClient.Items.item)
        item->SvmEventItem.toInternalItem(
          ~onEventRegistration=context.onEventRegistrations->Array.getUnsafe(registrationIndex),
          ~chainId=context.chainId,
        )
      | JsItem =>
        let item = tapeAt(row)->(Utils.magic: unknown => dict<unknown>)
        let kind = item->Dict.getUnsafe("kind")->(Utils.magic: unknown => int)
        item->Dict.set(
          kind === 0 ? "onEventRegistration" : "onBlockRegistration",
          jsItemRegistration(~kind, ~index=registrationIndex),
        )
        item->(Utils.magic: dict<unknown> => Internal.item)
      }
    })
  })

let toItems = (rows: EventStore.storedRows, ~context: context): array<Internal.item> =>
  rows->build(~context, ~jsItemRegistration=(~kind, ~index) =>
    kind === 0
      ? context.onEventRegistrations
        ->Array.getUnsafe(index)
        ->(Utils.magic: Internal.onEventRegistration => unknown)
      : context.onBlockRegistrations
        ->Array.getUnsafe(index)
        ->(Utils.magic: Internal.onBlockRegistration => unknown)
  )

// Removes the first `count` items from the store and returns them.
let take = (store: EventStore.t, count: int, ~context: context): array<Internal.item> =>
  store->EventStore.takeRaw(count)->toItems(~context)

// Every item in the store, which keeps them.
let allItems = (store: EventStore.t, ~context: context): array<Internal.item> =>
  store->EventStore.allItemsRaw->toItems(~context)

// The events routed to the given registrations, which the store keeps.
let eventsOfRegistrations = (
  store: EventStore.t,
  registrationIndexes: array<int>,
  ~context: context,
): array<Internal.item> =>
  store->EventStore.eventsOfRegistrationsRaw(registrationIndexes)->toItems(~context)
