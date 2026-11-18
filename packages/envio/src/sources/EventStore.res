// Binding to the Rust `EventStore` napi class: a chain's fetched items, kept
// in Rust in processing order, as columns, until a batch takes them. Each
// fetch response arrives as a page, merged into the chain's store once
// applied.
type t

@send external empty: Core.eventStoreCtor => t = "empty"

let make = () => Core.getAddon().eventStore->empty

// Which source item a row replays to, and so which conversion builds the
// `Internal.item`.
type format =
  | @as(0) EvmLog
  | @as(1) FuelReceipt
  | @as(2) SvmInstruction
  | @as(3) Block
  | @as(4) JsItem

// The columns of one arena, as `Reading` builds its views from them.
type arenaShape = {
  names: array<string>,
  kinds: array<Reading.kind>,
  elementKinds: array<Null.t<Reading.kind>>,
  rows: int,
}

// One registration's EVM log params, a row per log.
type paramsShape = {registrationIndex: int, shape: arenaShape}

// The transactions a joined take's items read from the chain's store, one
// each, for `TransactionStore.readFields`.
type transactionKeys = {
  blockNumbers: Float64Array.t,
  transactionIndexes: Uint32Array.t,
  masks: Float64Array.t,
}

// The same of the blocks, for `BlockStore.readFields`.
type blockKeys = {blockNumbers: Float64Array.t, masks: Float64Array.t}

// A batch's transactions or blocks read from the chain's stores: an arena with
// a row each and a column per selected field, and the nested fields, which
// have no column shape, beside it.
type fieldRows = {
  shape: arenaShape,
  accessList?: array<Nullable.t<unknown>>,
  authorizationList?: array<Nullable.t<unknown>>,
  accountActivities?: array<Nullable.t<unknown>>,
}

// A store's read of a batch's transactions or blocks, behind `handle`.
type fieldRead = {handle: int, rows: fieldRows}

// Items on their way to JS: the arenas behind `handle` hold `items`, a row per
// item in processing order, then each registration's `params`, then `fuel` and
// `svm`, then `links`: each item's row among the transactions and blocks it
// reads, whose keys `transactionKeys` and `blockKeys` give. `tapes` holds what has no column shape.
type storedRows = {
  handle: int,
  items: arenaShape,
  params: array<paramsShape>,
  // The whole item record of each Fuel receipt and SVM instruction row.
  fuel: arenaShape,
  svm: arenaShape,
  links: arenaShape,
  transactionKeys?: transactionKeys,
  blockKeys?: blockKeys,
  tapes: array<unknown>,
}

// The field-code masks of what each registration selects of its items'
// transaction and block: by event registration index, then by block
// registration index, null where a block handler reads only the number.
type joinedFields = {
  transactionMasks: array<float>,
  eventBlockMasks: array<float>,
  blockHandlerMasks: array<Null.t<float>>,
}

@send external lendRowsRaw: (Core.eventStoreCtor, int) => array<ArrayBuffer.t> = "lendRows"
@send
external releaseRowsRaw: (Core.eventStoreCtor, int, array<ArrayBuffer.t>) => unit = "releaseRows"

// Reads the arenas Rust holds under `handle` with `f`, then hands their
// buffers back, whether or not `f` throws. Nothing may keep a view into them.
let readHandle = (handle, f: array<ArrayBuffer.t> => 'a): 'a => {
  let ctor = Core.getAddon().eventStore
  let buffers = ctor->lendRowsRaw(handle)
  let result = try f(buffers) catch {
  | exn =>
    ctor->releaseRowsRaw(handle, buffers)
    throw(exn)
  }
  ctor->releaseRowsRaw(handle, buffers)
  result
}

// A JS-built item with its registration replaced by the registration's index.
type jsItemInput = {
  kind: int,
  blockNumber: int,
  logIndex: int,
  orderPath?: array<int>,
  registrationIndex: int,
  item: dict<unknown>,
  // Its transaction's key in the chain's store, when the item doesn't carry
  // the transaction itself.
  transactionIndex?: int,
  blockFromStore: bool,
}

@send external fromJsItemsRaw: (Core.eventStoreCtor, array<jsItemInput>) => t = "fromJsItems"

// A page of items built in JS (simulate input). Each item is stored as plain
// data without its registration, which `toItems` puts back by index.
let fromJsItems = (items: array<Internal.item>): t =>
  Core.getAddon().eventStore->fromJsItemsRaw(
    items->Array.map(item => {
      let data = item->(Utils.magic: Internal.item => dict<unknown>)->Dict.copy
      switch item {
      | Event({
          onEventRegistration,
          blockNumber,
          logIndex,
          ?orderPath,
          transactionIndex,
          payload,
        }) =>
        data->Dict.delete("onEventRegistration")
        {
          kind: 0,
          blockNumber,
          logIndex,
          ?orderPath,
          registrationIndex: onEventRegistration.index,
          item: data,
          transactionIndex: ?switch payload->Internal.getPayloadTransaction->Nullable.toOption {
          | Some(_) => None
          | None => Some(transactionIndex)
          },
          blockFromStore: payload->Internal.getPayloadBlock->Nullable.toOption->Option.isNone,
        }
      | Block({onBlockRegistration, blockNumber, ?block, ?skipped}) =>
        data->Dict.delete("onBlockRegistration")
        {
          kind: 1,
          blockNumber,
          logIndex: 0,
          registrationIndex: onBlockRegistration.index,
          item: data,
          blockFromStore: block->Option.isNone && skipped !== Some(true),
        }
      }
    }),
  )

// Moves the page's rows in, leaving the page empty. Of two rows for the same
// log and registration, the one already stored stays.
@send external merge: (t, t) => unit = "merge"

// Block handler items generated locally, one per (blockNumber,
// registrationIndex) pair.
@send
external insertBlockItems: (
  t,
  ~blockNumbers: array<int>,
  ~registrationIndexes: array<int>,
) => unit = "insertBlockItems"

@send external length: t => int = "len"
@send external blockNumberAt: (t, int) => Null.t<int> = "blockNumberAt"
@send external firstEventBlockNumber: t => Null.t<int> = "firstEventBlockNumber"

// How many rows are at or below the block.
@send external countAtOrBelow: (t, int) => int = "countAtOrBelow"

// How many rows a batch takes: those at or below `frontier`, up to
// `targetSize`, then the rest of the last block.
@send external readyCount: (t, ~frontier: int, ~targetSize: int) => int = "readyCount"

// Removes and returns the first rows, with the transactions and blocks they
// read from the chain's stores planned.
@send external takeJoinedRaw: (t, int, joinedFields) => storedRows = "takeJoined"

// Copies of the event rows routed to the given registrations, in order, with
// the transactions and blocks they read from the chain's stores planned.
@send
external eventsOfRegistrationsRaw: (t, array<int>, joinedFields) => storedRows =
  "eventsOfRegistrations"

// Drops every row above the block.
@send external rollback: (t, int) => unit = "rollback"
