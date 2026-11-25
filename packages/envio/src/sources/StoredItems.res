// Turns the items a chain buffer builds back into the items handlers receive,
// with each source's own item conversion.

// What rebuilding an item needs: the chain's registrations, by the index items
// carry.
type context = {
  chainId: ChainId.t,
  onEventRegistrations: array<Internal.onEventRegistration>,
  onBlockRegistrations: array<Internal.onBlockRegistration>,
  onTransactionRegistrations: array<Internal.onTransactionRegistration>,
}

// Which source item a row replays to, and so which conversion builds the
// `Internal.item`. Named as `ItemFormat` in `deliver.rs`.
type format =
  | @as(0) EvmLog
  | @as(1) FuelReceipt
  | @as(2) SvmInstruction
  | @as(3) Block
  | @as(4) Decoded
  | @as(5) Transaction

@get_index external numberAt: (array<unknown>, int) => float = ""
@get_index external valueAt: (array<unknown>, int) => 'a = ""

// One arena's rows as objects keyed by its column names. A column of tapes
// takes its values in before the objects are built, which keeps their shape
// stable; a row with no tape there gets `undefined`, as an absent field.
%%private(
  let objectsOf = (shape: ChainBuffer.arenaShape, ~tapes, ~buffers, ~cursor) => {
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

// A build's transactions or blocks as one object each, holding the fields a
// row has a value for.
%%private(
  let fieldObjects = (
    {shape, ?accessList, ?authorizationList, ?accountActivities}: ChainBuffer.fieldRows,
    ~buffers,
    ~cursor,
  ) => {
    let columns = Reading.columns(
      ~buffers,
      ~cursor,
      ~kinds=shape.kinds,
      ~elementKinds=shape.elementKinds,
      ~rows=shape.rows,
    )
    let objects = Array.fromInitializer(~length=shape.rows, _ => Dict.make())
    columns->Array.forEachWithIndex((column, index) => {
      let name = shape.names->Array.getUnsafe(index)
      column->Array.forEachWithIndex((value, row) =>
        if value !== %raw(`null`) {
          objects->Array.getUnsafe(row)->Dict.set(name, value)
        }
      )
    })
    objects->setNested(~name="accessList", accessList)
    objects->setNested(~name="authorizationList", authorizationList)
    objects->setNested(~name="accountActivities", accountActivities)
    objects
  }
)

// Each item's row among a build's transactions and blocks, null where it
// reads none, negative where it gets an empty object of its own.
type links = {
  transactionRows: array<unknown>,
  blockRows: array<unknown>,
}

// Gives each item the transaction and block its links point at. Items of one
// transaction or block share its object; where the batch selects no field of
// either, each item gets an empty object of its own. An EVM transaction also
// carries its block, as an event's and a transaction handler's alike.
%%private(
  let attach = (
    items: array<Internal.item>,
    toRead: links,
    ~transactions,
    ~blocks,
    ~isEvmRow: int => bool,
  ) =>
    items->Array.forEachWithIndex((item, row) => {
      let transaction = switch toRead.transactionRows
      ->valueAt(row)
      ->(Utils.magic: unknown => Null.t<float>) {
      | Value(link) =>
        let transaction =
          link < 0.
            ? %raw(`{}`)
            : transactions
              ->Array.getUnsafe(link->Float.toInt)
              ->(Utils.magic: dict<unknown> => Internal.eventTransaction)
        switch item {
        | Transaction(_) => item->Internal.setItemTransaction(transaction)
        | Event({payload}) =>
          payload->Internal.setPayloadTransaction(transaction)
          if (
            transaction
            ->(Utils.magic: Internal.eventTransaction => dict<unknown>)
            ->Dict.has("accountActivities")
          ) {
            Svm.attachAccountActivities(payload, transaction)
          }
        | Block(_) => ()
        }
        Some(transaction)
      | Null => None
      }
      switch toRead.blockRows->valueAt(row)->(Utils.magic: unknown => Null.t<float>) {
      | Value(link) =>
        let block =
          link < 0.
            ? %raw(`{}`)
            : blocks
              ->Array.getUnsafe(link->Float.toInt)
              ->(Utils.magic: dict<unknown> => Internal.eventBlock)
        switch item {
        | Event({payload}) => payload->Internal.payloadBlockHolder->Internal.setHolderBlock(block)
        | Block(_) => item->Internal.itemBlockHolder->Internal.setHolderBlock(block)
        | Transaction(_) => ()
        }
        switch transaction {
        | Some(transaction) if isEvmRow(row) =>
          transaction
          ->(Utils.magic: Internal.eventTransaction => Internal.blockHolder)
          ->Internal.setHolderBlock(block)
        | _ => ()
        }
      | Null => ()
      }
    })
)

// Every built item as the item its handler receives, with its transaction and
// block.
let read = (rows: ChainBuffer.builtItems, ~context: context): array<Internal.item> =>
  ChainBuffer.readHandle(rows.handle, buffers => {
    let cursor = ref(0)
    let columns = Reading.columns(
      ~buffers,
      ~cursor,
      ~kinds=rows.items.kinds,
      ~elementKinds=rows.items.elementKinds,
      ~rows=rows.items.rows,
    )
    // Named as `ITEM_COLUMNS` in `chain_buffer/deliver.rs`.
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
    // `FORMAT_BITS` in `deliver.rs`: the format below, the row above.
    let detailRow = row => details->numberAt(row)->Float.toInt->Int.shiftRightUnsigned(3)
    let tapeAt = row => rows.tapes->Array.getUnsafe(tapePositions->numberAt(row)->Float.toInt)
    let items = Array.fromInitializer(~length=rows.items.rows, row => {
      let registrationIndex = registrationIndexes->numberAt(row)->Float.toInt
      switch details
      ->numberAt(row)
      ->Float.toInt
      ->Int.bitwiseAnd(7)
      ->(Utils.magic: int => format) {
      | EvmLog =>
        EvmEventItem.toInternalItem(
          // Not Float.toInt: its `| 0` wraps a log index above 2^31 - 1,
          // which some providers emit, into a negative one.
          ~logIndex=logIndexes->numberAt(row)->(Utils.magic: float => int),
          ~srcAddress=srcAddresses->valueAt(row),
          ~blockNumber=blockNumbers->numberAt(row)->Float.toInt,
          ~transactionIndex=transactionIndexes->numberAt(row)->Float.toInt,
          ~params=params
          ->Array.getUnsafe(registrationIndex)
          ->Array.getUnsafe(row->detailRow)
          ->(Utils.magic: dict<unknown> => Internal.eventParams),
          ~onEventRegistration=context.onEventRegistrations
          ->Array.getUnsafe(registrationIndex)
          ->(Utils.magic: Internal.onEventRegistration => Internal.evmOnEventRegistration),
          ~chainId=context.chainId,
        )
      | Transaction =>
        Internal.Transaction({
          onTransactionRegistration: context.onTransactionRegistrations->Array.getUnsafe(
            registrationIndex,
          ),
          blockNumber: blockNumbers->numberAt(row)->Float.toInt,
          transactionIndex: transactionIndexes->numberAt(row)->Float.toInt,
        })
      | Block =>
        let skipped: bool = skipped->valueAt(row)
        Internal.Block({
          onBlockRegistration: context.onBlockRegistrations->Array.getUnsafe(registrationIndex),
          blockNumber: blockNumbers->numberAt(row)->Float.toInt,
          skipped: ?(skipped ? Some(true) : None),
        })
      | FuelReceipt =>
        let item =
          fuel
          ->Array.getUnsafe(row->detailRow)
          ->(Utils.magic: dict<unknown> => FuelEventItem.item)
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
      | Decoded =>
        let item = tapeAt(row)->(Utils.magic: unknown => dict<unknown>)
        switch item->Dict.getUnsafe("kind")->(Utils.magic: unknown => int) {
        | 0 =>
          item->Dict.set(
            "onEventRegistration",
            context.onEventRegistrations
            ->Array.getUnsafe(registrationIndex)
            ->(Utils.magic: Internal.onEventRegistration => unknown),
          )
        | _ =>
          item->Dict.set(
            "onBlockRegistration",
            context.onBlockRegistrations
            ->Array.getUnsafe(registrationIndex)
            ->(Utils.magic: Internal.onBlockRegistration => unknown),
          )
        }
        item->(Utils.magic: dict<unknown> => Internal.item)
      }
    })
    let links = rows.links
    let linkColumns = Reading.columns(
      ~buffers,
      ~cursor,
      ~kinds=links.kinds,
      ~elementKinds=links.elementKinds,
      ~rows=links.rows,
    )
    // Named as `link_columns` in `deliver.rs`.
    let linkColumn = name => linkColumns->Array.getUnsafe(links.names->Array.indexOf(name))
    let transactions = switch rows.transactions {
    | Some(fieldRows) => fieldRows->fieldObjects(~buffers, ~cursor)
    | None => []
    }
    let blocks = switch rows.blocks {
    | Some(fieldRows) => fieldRows->fieldObjects(~buffers, ~cursor)
    | None => []
    }
    items->attach(
      {transactionRows: linkColumn("transactionRow"), blockRows: linkColumn("blockRow")},
      ~transactions,
      ~blocks,
      ~isEvmRow=row =>
        switch details
        ->numberAt(row)
        ->Float.toInt
        ->Int.bitwiseAnd(7)
        ->(Utils.magic: int => format) {
        | EvmLog | Transaction => true
        | _ => false
        },
    )
    items
  })
