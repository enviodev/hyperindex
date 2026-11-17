// Turns the rows an `EventStore` hands out back into the items handlers
// receive, with each source's own item conversion.

// What rebuilding an item from its row needs: the chain's registrations, by
// the index rows carry.
type context = {
  chainId: ChainId.t,
  onEventRegistrations: array<Internal.onEventRegistration>,
  onBlockRegistrations: array<Internal.onBlockRegistration>,
}

// Where a batch's transactions and blocks come from: the chain's stores, and
// how the chain spells addresses.
type fields = {
  transactionStore: TransactionStore.t,
  blockStore: BlockStore.t,
  shouldChecksum: bool,
}

// What each registration selects of its items' transaction and block, as the
// take reads them from the stores.
%%private(
  let joinedFields = (context: context, fields: fields): EventStore.joinedFields => {
    transactionMasks: context.onEventRegistrations->Array.map(registration =>
      registration.fieldSelection.transactionMask
    ),
    eventBlockMasks: context.onEventRegistrations->Array.map(registration =>
      registration.fieldSelection.blockMask
    ),
    blockHandlerMasks: context.onBlockRegistrations->Array.map(registration =>
      registration.blockFieldMask->Null.fromOption
    ),
    shouldChecksum: fields.shouldChecksum,
  }
)

@get_index external numberAt: (array<unknown>, int) => float = ""
@get_index external valueAt: (array<unknown>, int) => 'a = ""

// One arena's rows as objects keyed by its column names. A column of tapes
// takes its values in before the objects are built, which keeps their shape
// stable; a row with no tape there gets `undefined`, as an absent field.
%%private(
  let objectsOf = (shape: EventStore.arenaShape, ~tapes, ~buffers, ~cursor) => {
    let columns = Reading.columns(
      ~buffers,
      ~cursor,
      ~kinds=shape.kinds,
      ~elementKinds=shape.elementKinds,
      ~rows=shape.rows,
    )
    shape.kinds->Array.forEachWithIndex((kind, index) =>
      if kind === Reading.Tape {
        columns->Array.setUnsafe(
          index,
          columns
          ->Array.getUnsafe(index)
          ->Array.map(position =>
            switch position->(Utils.magic: unknown => Null.t<int>) {
            | Value(position) => tapes->Array.getUnsafe(position)
            | Null => %raw(`undefined`)
            }
          ),
        )
      }
    )
    columns->Reading.objects(~names=shape.names, ~rows=shape.rows)
  }
)

%%private(
  let setNested = (objects: array<dict<unknown>>, ~name, values) =>
    switch values {
    | Some(values) =>
      values->Array.forEachWithIndex((value, row) =>
        switch value {
        | Nullable.Value(value) => objects->Array.getUnsafe(row)->Dict.set(name, value)
        | _ => ()
        }
      )
    | None => ()
    }
)

// A joined result's transactions or blocks as one object each. A field a row
// has no value for is `undefined`, as an absent field.
%%private(
  let fieldObjects = (rows: option<EventStore.fieldRows>, ~buffers, ~cursor) =>
    switch rows {
    | None => []
    | Some({shape, ?accessList, ?authorizationList, ?accountActivities}) =>
      let columns = Reading.columns(
        ~buffers,
        ~cursor,
        ~kinds=shape.kinds,
        ~elementKinds=shape.elementKinds,
        ~rows=shape.rows,
      )
      columns->Array.forEach(column =>
        column->Array.forEachWithIndex((value, row) =>
          if value === %raw(`null`) {
            column->Array.setUnsafe(row, %raw(`undefined`))
          }
        )
      )
      let objects = columns->Reading.objects(~names=shape.names, ~rows=shape.rows)
      objects->setNested(~name="accessList", accessList)
      objects->setNested(~name="authorizationList", authorizationList)
      objects->setNested(~name="accountActivities", accountActivities)
      objects
    }
)

// Gives each item of a joined result its transaction and block. Items of one
// transaction or block share its object; an item whose transaction is read
// from the store while the batch selects no transaction field gets an empty
// object of its own.
%%private(
  let attachJoined = (
    items: array<Internal.item>,
    links,
    ~transactions,
    ~blocks,
    ~buffers,
    ~cursor,
  ) => {
    let columns = Reading.columns(
      ~buffers,
      ~cursor,
      ~kinds=links.EventStore.kinds,
      ~elementKinds=links.elementKinds,
      ~rows=links.rows,
    )
    let transactionObjects = transactions->fieldObjects(~buffers, ~cursor)
    let blockObjects = blocks->fieldObjects(~buffers, ~cursor)
    // In the order `link_columns` in `event_store.rs` lays them out.
    let transactionRows = columns->Array.getUnsafe(0)
    let blockRows = columns->Array.getUnsafe(1)
    items->Array.forEachWithIndex((item, row) => {
      switch transactionRows->valueAt(row)->(Utils.magic: unknown => Null.t<float>) {
      | Value(link) =>
        let payload = (item->Internal.castUnsafeEventItem).payload
        if link < 0. {
          payload->Internal.setPayloadTransaction(%raw(`{}`))
        } else {
          let transaction =
            transactionObjects
            ->Array.getUnsafe(link->Float.toInt)
            ->(Utils.magic: dict<unknown> => Internal.eventTransaction)
          payload->Internal.setPayloadTransaction(transaction)
          if (
            transaction
            ->(Utils.magic: Internal.eventTransaction => dict<unknown>)
            ->Dict.has("accountActivities")
          ) {
            Svm.attachAccountActivities(payload, transaction)
          }
        }
      | Null => ()
      }
      switch blockRows->valueAt(row)->(Utils.magic: unknown => Null.t<float>) {
      | Value(link) =>
        let holder = switch item {
        | Event({payload}) => payload->Internal.payloadBlockHolder
        | Block(_) => item->Internal.itemBlockHolder
        }
        holder->Internal.setHolderBlock(
          blockObjects
          ->Array.getUnsafe(link->Float.toInt)
          ->(Utils.magic: dict<unknown> => Internal.eventBlock),
        )
      | Null => ()
      }
    })
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
    let details = column(0)
    let blockNumbers = column(1)
    let logIndexes = column(2)
    let transactionIndexes = column(3)
    let registrationIndexes = column(4)
    let srcAddresses = column(5)
    let skipped = column(6)
    let tapePositions = column(7)
    let params = []
    rows.params->Array.forEach(({registrationIndex, shape}) =>
      params->Array.setUnsafe(
        registrationIndex,
        shape->objectsOf(~tapes=rows.tapes, ~buffers, ~cursor),
      )
    )
    let fuel = rows.fuel->objectsOf(~tapes=rows.tapes, ~buffers, ~cursor)
    let svm = rows.svm->objectsOf(~tapes=rows.tapes, ~buffers, ~cursor)
    // `FORMAT_BITS` in `event_store.rs`: the format below, the row above.
    let detailRow = row => details->numberAt(row)->Float.toInt->Int.shiftRightUnsigned(3)
    let tapeAt = row => rows.tapes->Array.getUnsafe(tapePositions->numberAt(row)->Float.toInt)
    let items = Array.fromInitializer(~length=rows.items.rows, row => {
      let registrationIndex = registrationIndexes->numberAt(row)->Float.toInt
      switch details
      ->numberAt(row)
      ->Float.toInt
      ->Int.bitwiseAnd(7)
      ->(Utils.magic: int => EventStore.format) {
      | EvmLog =>
        let item: EvmEventItem.t = {
          logIndex: logIndexes->numberAt(row)->Float.toInt,
          srcAddress: srcAddresses->valueAt(row),
          blockNumber: blockNumbers->numberAt(row)->Float.toInt,
          transactionIndex: transactionIndexes->numberAt(row)->Float.toInt,
          onEventRegistrationIndex: registrationIndex,
          params: params
          ->Array.getUnsafe(registrationIndex)
          ->Array.getUnsafe(row->detailRow)
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
        let item =
          fuel
          ->Array.getUnsafe(row->detailRow)
          ->(Utils.magic: dict<unknown> => FuelHyperSyncClient.EventItems.item)
        item->FuelEventItem.toInternalItem(
          ~onEventRegistration=context.onEventRegistrations->Array.getUnsafe(registrationIndex),
          ~chainId=context.chainId,
        )
      | SvmInstruction =>
        let item =
          svm
          ->Array.getUnsafe(row->detailRow)
          ->(Utils.magic: dict<unknown> => SvmHyperSyncClient.Items.item)
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
    switch rows.links {
    | Some(links) =>
      items->attachJoined(
        links,
        ~transactions=rows.transactions,
        ~blocks=rows.blocks,
        ~buffers,
        ~cursor,
      )
    | None => ()
    }
    items
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

// Removes the first `count` items from the store and returns them, with
// their transactions and blocks when `fields` says where to read them.
let take = (store: EventStore.t, count: int, ~context: context, ~fields=?): array<Internal.item> =>
  switch fields {
  | Some(fields) =>
    store
    ->EventStore.takeJoinedRaw(
      count,
      fields.transactionStore,
      fields.blockStore,
      joinedFields(context, fields),
    )
    ->toItems(~context)
  | None => store->EventStore.takeRaw(count)->toItems(~context)
  }

// Every item in the store, which keeps them.
let allItems = (store: EventStore.t, ~context: context): array<Internal.item> =>
  store->EventStore.allItemsRaw->toItems(~context)

// The events routed to the given registrations, which the store keeps, with
// their transactions and blocks.
let eventsOfRegistrations = (
  store: EventStore.t,
  registrationIndexes: array<int>,
  ~context: context,
  ~fields: fields,
): array<Internal.item> =>
  store
  ->EventStore.eventsOfRegistrationsRaw(
    registrationIndexes,
    fields.transactionStore,
    fields.blockStore,
    joinedFields(context, fields),
  )
  ->toItems(~context)
