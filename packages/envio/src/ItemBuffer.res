// Binding to the Rust `ItemBuffer` napi class: a chain's fetched items in
// processing order. Rust orders, deduplicates and slices the buffer by each
// item's key; the items stay here, each at the slot Rust assigned it.
//
// Mutable, unlike the fetch state record holding it: every copy of a fetch
// state shares one buffer, the way it shares `mutPendingQueries`.
type native

@send external makeNative: Core.itemBufferCtor => native = "make"
@send external insertNative: (native, Int32Array.t, Int32Array.t) => Int32Array.t = "insert"
@get external lengthNative: native => int = "length"
@send external blockNumberAtNative: (native, int) => Null.t<int> = "blockNumberAt"
@send external readyCountNative: (native, int) => int = "readyCount"
@send external readyItemsCountNative: (native, int, int, int) => int = "readyItemsCount"
@send external peekSlotsNative: (native, int) => Uint32Array.t = "peekSlots"
@send external newEventFlagsNative: (native, int) => Uint8Array.t = "newEventFlags"
@send external consumeNative: (native, int) => Uint32Array.t = "consume"
@send external truncateAboveNative: (native, int) => Uint32Array.t = "truncateAbove"

type t = {
  native: native,
  // Indexed by slot. A freed slot is cleared so the item can be collected.
  slots: array<Nullable.t<Internal.item>>,
}

let make = (): t => {native: Core.getAddon().itemBuffer->makeNative, slots: []}

let keyWidth = 5
let noOrderPath = -1

let getRegistrationIndex = (item: Internal.item): int =>
  switch item {
  | Event({onEventRegistration}) => onEventRegistration.index
  | Block({onBlockRegistration}) => onBlockRegistration.index
  }

// Merges `items`, in any order, into the buffer, dropping each one equal to an
// item already buffered or to an earlier one of `items`: the same log routed to
// the same registration, which an overlapping query can deliver twice.
let insert = (buffer: t, items: array<Internal.item>) => {
  let count = items->Array.length
  if count > 0 {
    let keys = Int32Array.fromLength(count * keyWidth)
    let orderPaths = []
    for idx in 0 to count - 1 {
      let item = items->Array.getUnsafe(idx)
      let offset = idx * keyWidth
      let kind = item->Internal.getItemKind
      keys->TypedArray.set(offset, item->Internal.getItemBlockNumber)
      keys->TypedArray.set(offset + 1, kind)
      // A block item has no log index; the key orders on it only between
      // items of the same kind.
      keys->TypedArray.set(offset + 2, kind === 0 ? item->Internal.getItemLogIndex : 0)
      keys->TypedArray.set(offset + 3, item->getRegistrationIndex)
      keys->TypedArray.set(
        offset + 4,
        switch item->Internal.getItemOrderPath {
        | Value(path) =>
          orderPaths->Array.pushMany(path)
          path->Array.length
        | Null | Undefined => noOrderPath
        },
      )
    }
    let assigned = buffer.native->insertNative(keys, orderPaths->Int32Array.fromArray)
    for idx in 0 to count - 1 {
      let slot = assigned->TypedArray.get(idx)->Option.getUnsafe
      if slot >= 0 {
        buffer.slots->Array.setUnsafe(slot, Nullable.make(items->Array.getUnsafe(idx)))
      }
    }
  }
}

let fromItems = (items: array<Internal.item>): t => {
  let buffer = make()
  buffer->insert(items)
  buffer
}

let length = (buffer: t) => buffer.native->lengthNative

let blockNumberAt = (buffer: t, index) => buffer.native->blockNumberAtNative(index)->Null.toOption

// Items at or below `frontier`: the buffer is sorted, so they are a prefix.
let readyCount = (buffer: t, ~frontier) => buffer.native->readyCountNative(frontier)

// Ready items from `fromItem` on: `targetSize` of them, extended to the end of
// the last one's block, or every ready item when fewer are ready.
let readyItemsCount = (buffer: t, ~targetSize, ~fromItem, ~frontier) =>
  buffer.native->readyItemsCountNative(targetSize, fromItem, frontier)

let itemAt = (buffer: t, slot) =>
  buffer.slots->Array.getUnsafe(slot)->(Utils.magic: Nullable.t<Internal.item> => Internal.item)

let itemsOfSlots = (buffer: t, slots: Uint32Array.t) =>
  Array.fromInitializer(~length=slots->TypedArray.length, idx =>
    buffer->itemAt(slots->TypedArray.get(idx)->Option.getUnsafe)
  )

// The first `count` items, left in the buffer.
let peek = (buffer: t, ~count) => buffer->itemsOfSlots(buffer.native->peekSlotsNative(count))

// Per each of the first `count` items, whether it is the first item of its log:
// a log routed to several registrations is one event.
let newEventFlags = (buffer: t, ~count) => buffer.native->newEventFlagsNative(count)

let release = (buffer: t, slots: Uint32Array.t) =>
  for idx in 0 to slots->TypedArray.length - 1 {
    buffer.slots->Array.setUnsafe(slots->TypedArray.get(idx)->Option.getUnsafe, Nullable.undefined)
  }

// Removes the first `count` items.
let consume = (buffer: t, ~count) => buffer->release(buffer.native->consumeNative(count))

// Removes every item above `blockNumber`.
let truncateAbove = (buffer: t, ~blockNumber) =>
  buffer->release(buffer.native->truncateAboveNative(blockNumber))

let toArray = (buffer: t) => buffer->peek(~count=buffer->length)
