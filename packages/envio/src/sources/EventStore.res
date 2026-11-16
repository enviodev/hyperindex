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

type storedItem = {
  format: format,
  registrationIndex: int,
  data: unknown,
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
@send external takeRaw: (t, int) => array<storedItem> = "take"

// Copies of the event rows routed to the given registrations, in order.
@send
external eventsOfRegistrationsRaw: (t, array<int>) => array<storedItem> = "eventsOfRegistrations"

// Copies of every row, in order.
@send external allItemsRaw: t => array<storedItem> = "allItems"

// Drops every row above the block.
@send external rollback: (t, int) => unit = "rollback"
