// Binding to the Rust `EventStore` napi class: a chain's fetched items, kept
// in Rust in processing order until a batch takes them. A row holds the
// source's own item object, which becomes JS only when read. Each fetch
// response arrives as a page, merged into the chain's store once applied.
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

// Items on their way to JS: the arenas behind `handle` hold `items`, a row per
// item in processing order, then each registration's `params`. `tapes` holds
// what has no column shape. `read` lends the arenas and takes them back.
type storedRows = {
  handle: int,
  items: arenaShape,
  params: array<paramsShape>,
  tapes: array<unknown>,
}

@send external lendRowsRaw: (Core.eventStoreCtor, int) => array<ArrayBuffer.t> = "lendRows"
@send
external releaseRowsRaw: (Core.eventStoreCtor, int, array<ArrayBuffer.t>) => unit = "releaseRows"

// Reads the arenas behind `rows` with `f`, then hands their buffers back,
// whether or not `f` throws. Nothing may keep a view into them.
let read = (rows: storedRows, f: array<ArrayBuffer.t> => 'a): 'a => {
  let ctor = Core.getAddon().eventStore
  let buffers = ctor->lendRowsRaw(rows.handle)
  let result = try f(buffers) catch {
  | exn =>
    ctor->releaseRowsRaw(rows.handle, buffers)
    throw(exn)
  }
  ctor->releaseRowsRaw(rows.handle, buffers)
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
}

@send external fromJsItemsRaw: (Core.eventStoreCtor, array<jsItemInput>) => t = "fromJsItems"

// A page of items built in JS (simulate input). Each item is stored as plain
// data without its registration, which `toItems` puts back by index.
let fromJsItems = (items: array<Internal.item>): t =>
  Core.getAddon().eventStore->fromJsItemsRaw(
    items->Array.map(item => {
      let data = item->(Utils.magic: Internal.item => dict<unknown>)->Dict.copy
      switch item {
      | Event({onEventRegistration, blockNumber, logIndex, ?orderPath}) =>
        data->Dict.delete("onEventRegistration")
        {
          kind: 0,
          blockNumber,
          logIndex,
          ?orderPath,
          registrationIndex: onEventRegistration.index,
          item: data,
        }
      | Block({onBlockRegistration, blockNumber}) =>
        data->Dict.delete("onBlockRegistration")
        {
          kind: 1,
          blockNumber,
          logIndex: 0,
          registrationIndex: onBlockRegistration.index,
          item: data,
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

// How many rows from `fromIndex` on a batch takes: those at or below
// `frontier`, up to `targetSize`, then the rest of the last block.
@send
external readyCount: (t, ~frontier: int, ~targetSize: int, ~fromIndex: int) => int = "readyCount"

// Removes and returns the first rows.
@send external takeRaw: (t, int) => storedRows = "take"

// Copies of the event rows routed to the given registrations, in order.
@send
external eventsOfRegistrationsRaw: (t, array<int>) => storedRows = "eventsOfRegistrations"

// Copies of every row, in order.
@send external allItemsRaw: t => storedRows = "allItems"

// Drops every row above the block.
@send external rollback: (t, int) => unit = "rollback"
