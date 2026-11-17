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
  let joinedFields = (context: context): EventStore.joinedFields => {
    transactionMasks: context.onEventRegistrations->Array.map(registration =>
      registration.fieldSelection.transactionMask
    ),
    eventBlockMasks: context.onEventRegistrations->Array.map(registration =>
      registration.fieldSelection.blockMask
    ),
    blockHandlerMasks: context.onBlockRegistrations->Array.map(registration =>
      registration.blockFieldMask->Null.fromOption
    ),
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

// A store's read of a batch's transactions or blocks as one object each,
// holding the fields a row has a value for.
%%private(
  let fieldObjects = (
    {
      handle,
      rows: {shape, ?accessList, ?authorizationList, ?accountActivities},
    }: EventStore.fieldRead,
  ) => {
    let objects = EventStore.readHandle(handle, buffers => {
      let columns = Reading.columns(
        ~buffers,
        ~cursor=ref(0),
        ~kinds=shape.kinds,
        ~elementKinds=shape.elementKinds,
        ~rows=shape.rows,
      )
      let objects = Array.fromInitializer(~length=shape.rows, _ => Dict.make())
      columns->Array.forEachWithIndex((column, index) => {
        let name = shape.names->Array.getUnsafe(index)
        column->Array.forEachWithIndex(
          (value, row) =>
            if value !== %raw(`null`) {
              objects->Array.getUnsafe(row)->Dict.set(name, value)
            },
        )
      })
      objects
    })
    objects->setNested(~name="accessList", accessList)
    objects->setNested(~name="authorizationList", authorizationList)
    objects->setNested(~name="accountActivities", accountActivities)
    objects
  }
)

// What a joined take's items read from the chain's stores: each item's row
// among the transactions and among the blocks, null where it reads none, and
// the keys the stores read those rows by.
type fieldsToRead = {
  transactionRows: array<unknown>,
  blockRows: array<unknown>,
  transactionKeys: option<EventStore.transactionKeys>,
  blockKeys: option<EventStore.blockKeys>,
}

// Gives each item the transaction and block its links point at. Items of one
// transaction or block share its object; where the batch selects no field of
// either, each item gets an empty object of its own.
%%private(
  let attach = (items: array<Internal.item>, toRead: fieldsToRead, ~transactions, ~blocks) =>
    items->Array.forEachWithIndex((item, row) => {
      switch toRead.transactionRows->valueAt(row)->(Utils.magic: unknown => Null.t<float>) {
      | Value(link) =>
        let payload = (item->Internal.castUnsafeEventItem).payload
        if link < 0. {
          payload->Internal.setPayloadTransaction(%raw(`{}`))
        } else {
          let transaction =
            transactions
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
      switch toRead.blockRows->valueAt(row)->(Utils.magic: unknown => Null.t<float>) {
      | Value(link) =>
        let holder = switch item {
        | Event({payload}) => payload->Internal.payloadBlockHolder
        | Block(_) => item->Internal.itemBlockHolder
        }
        holder->Internal.setHolderBlock(
          link < 0.
            ? %raw(`{}`)
            : blocks
              ->Array.getUnsafe(link->Float.toInt)
              ->(Utils.magic: dict<unknown> => Internal.eventBlock),
        )
      | Null => ()
      }
    })
)

// Reads the transactions and blocks `items` were taken with, off the JS
// thread, then gives each item its own.
%%private(
  let readFields = async (items: array<Internal.item>, toRead: fieldsToRead, ~fields: fields) => {
    let transactionsRead = switch toRead.transactionKeys {
    | Some({blockNumbers, transactionIndexes, masks}) =>
      fields.transactionStore
      ->TransactionStore.readFields(blockNumbers, transactionIndexes, masks, fields.shouldChecksum)
      ->Promise.thenResolve(read => read->fieldObjects)
    | None => Promise.resolve([])
    }
    let blocksRead = switch toRead.blockKeys {
    | Some({blockNumbers, masks}) =>
      fields.blockStore
      ->BlockStore.readFields(blockNumbers, masks, fields.shouldChecksum)
      ->Promise.thenResolve(read => read->fieldObjects)
    | None => Promise.resolve([])
    }
    let (transactions, blocks) = await Promise.all2((transactionsRead, blocksRead))
    items->attach(toRead, ~transactions, ~blocks)
  }
)

// Every row as an item. A JS-built row gets its registration back from
// `jsItemRegistration`, given the item's kind (0 for an event) and the index
// it was stored under.
%%private(
  let buildReading = (
    rows: EventStore.storedRows,
    ~context: context,
    ~jsItemRegistration: (~kind: int, ~index: int) => unknown,
  ): (array<Internal.item>, option<fieldsToRead>) =>
    EventStore.readHandle(rows.handle, buffers => {
      let cursor = ref(0)
      let columns = Reading.columns(
        ~buffers,
        ~cursor,
        ~kinds=rows.items.kinds,
        ~elementKinds=rows.items.elementKinds,
        ~rows=rows.items.rows,
      )
      // Named as `ITEM_COLUMNS` in `event_store.rs`.
      let column = name => columns->Array.getUnsafe(rows.items.names->Array.indexOf(name))
      let details = column("detail")
      let blockNumbers = column("blockNumber")
      let logIndexes = column("logIndex")
      let transactionIndexes = column("transactionIndex")
      let registrationIndexes = column("registrationIndex")
      let srcAddresses = column("srcAddress")
      let skipped = column("skipped")
      let tapePositions = column("tape")
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
      let toRead = rows.links->Option.map(links => {
        let columns = Reading.columns(
          ~buffers,
          ~cursor,
          ~kinds=links.kinds,
          ~elementKinds=links.elementKinds,
          ~rows=links.rows,
        )
        // Named as `link_columns` in `event_store.rs`.
        let column = name => columns->Array.getUnsafe(links.names->Array.indexOf(name))
        {
          transactionRows: column("transactionRow"),
          blockRows: column("blockRow"),
          transactionKeys: rows.transactionKeys,
          blockKeys: rows.blockKeys,
        }
      })
      (items, toRead)
    })
)

let build = (rows, ~context, ~jsItemRegistration) => {
  let (items, _) = rows->buildReading(~context, ~jsItemRegistration)
  items
}

%%private(
  let toItemsReading = (rows: EventStore.storedRows, ~context: context) =>
    rows->buildReading(~context, ~jsItemRegistration=(~kind, ~index) =>
      kind === 0
        ? context.onEventRegistrations
          ->Array.getUnsafe(index)
          ->(Utils.magic: Internal.onEventRegistration => unknown)
        : context.onBlockRegistrations
          ->Array.getUnsafe(index)
          ->(Utils.magic: Internal.onBlockRegistration => unknown)
    )
)

// Items with the read that gives them their transactions and blocks before
// handlers run. Where nothing is read from the stores, they get them now.
%%private(
  let withFields = ((items, toRead), ~fields: fields): (
    array<Internal.item>,
    unit => promise<unit>,
  ) =>
    switch toRead {
    | Some({transactionKeys: None, blockKeys: None} as toRead) =>
      items->attach(toRead, ~transactions=[], ~blocks=[])
      (items, () => Promise.resolve())
    | Some(toRead) => (items, () => items->readFields(toRead, ~fields))
    | None => (items, () => Promise.resolve())
    }
)

// Removes the first `count` items from the store and returns them, with the
// read that gives them their transactions and blocks.
let takeWithFields = (store: EventStore.t, count: int, ~context: context, ~fields: fields) =>
  store
  ->EventStore.takeJoinedRaw(count, joinedFields(context))
  ->toItemsReading(~context)
  ->withFields(~fields)

// The events routed to the given registrations, which the store keeps, with
// the read that gives them their transactions and blocks.
let eventsOfRegistrations = (
  store: EventStore.t,
  registrationIndexes: array<int>,
  ~context: context,
  ~fields: fields,
) =>
  store
  ->EventStore.eventsOfRegistrationsRaw(registrationIndexes, joinedFields(context))
  ->toItemsReading(~context)
  ->withFields(~fields)
