type name = | @as("evm") Evm | @as("fuel") Fuel | @as("svm") Svm

/** What a block handler's `fields` option selects from. */
type onBlockFields = {
  /** In store order: a field's index is its bit in the block store's mask. */
  fields: array<string>,
  /** The field keying a block in the store, which a handler always has. */
  keyField: string,
  mask: Utils.Set.t<string> => float,
}

type t = {
  name: name,
  blockNumberName: string,
  blockTimestampName: string,
  blockHashName: string,
  /** `None` where block handlers get the block's key alone (Fuel). */
  onBlockFields: option<onBlockFields>,
  /** Method name that the block handler is exposed under on the public
      `indexer` object — `"onBlock"` for chain-based ecosystems, `"onSlot"`
      for SVM. Centralised here so adding a new ecosystem only requires a
      new ecosystem record, not another switch in `Main.res`. */
  onBlockMethodName: string,
  /** What the ecosystem calls a contract and one of its events, for
      registration errors that are shared across ecosystems — "contract" /
      "event" on EVM and Fuel, "program" / "instruction" on SVM. */
  contractNoun: string,
  eventNoun: string,
  /** Schema that unwraps the ecosystem-specific outer wrapper around the
      user's `where`-returned filter (`block.number` on EVM, `block.height`
      on Fuel, `slot` on SVM) and surfaces the raw inner `{_gte?, _lte?,
      _every?}` chunk as `option<unknown>`. The inner chunk is then parsed
      a second time in `Main.res` by the shared `blockRangeSchema` — that
      keeps range-field validation in one place for every ecosystem. */
  onBlockFilterSchema: S.t<option<unknown>>,
  /** Schema that unwraps the ecosystem-specific `block` wrapper from the
      user's `onEvent` `where` value (`block.number` on EVM, `block.height`
      on Fuel) and surfaces the raw inner `{_gte?}` chunk as
      `option<unknown>`. Separate from `onBlockFilterSchema` because event
      block filters support only `_gte` (→ per-event `startBlock`) — `_lte`
      and `_every` are rejected by the inner `eventBlockRangeSchema` in
      `LogSelection.res`. SVM parses its own `where` (including the
      `block.slot` chunk), so its schema always surfaces `None`. */
  onEventBlockFilterSchema: S.t<option<unknown>>,
  /** Materialise the user-facing event handed to handlers and contract
      registration from an item's opaque payload. `event.transaction` is written
      onto the payload at batch prep (HyperSync) or inline (RPC/simulate). */
  toEvent: Internal.eventItem => Internal.event,
  /** Build the per-item child logger for an event item, with
      ecosystem-specific log fields (EVM/Fuel: contract/event/address; SVM:
      program/instruction/programId), on top of the logger it's given. */
  withEventFields: (Internal.eventItem, ~logger: Logger.t) => Logger.t,
  /** Build a raw event row for the `raw_events` table. Unsupported on SVM,
      where the implementation throws. */
  toRawEvent: Internal.eventItem => Internal.rawEvent,
}

// The materialised event and the child logger are both memoised on the item
// object (an item is processed across preload + execution passes, and logged
// from several places). Hidden keys mirror each other.
let getItemEvent = {
  let cacheKey = "_event"
  (item: Internal.item, ~ecosystem: t): Internal.event => {
    let cache = item->(Utils.magic: Internal.item => dict<Internal.event>)
    switch cache->Utils.Dict.dangerouslyGetNonOption(cacheKey) {
    | Some(event) => event
    | None =>
      let event = ecosystem.toEvent(item->Internal.castUnsafeEventItem)
      cache->Dict.set(cacheKey, event)
      event
    }
  }
}

// Made for each line rather than kept on the item: building one costs a few
// hundred nanoseconds, and only a line that passes the level asks for it.
let loggerForItem = (item: Internal.item, ~ecosystem: t, ~logger: Logger.t): Logger.t =>
  switch item {
  | Internal.Event(_) => ecosystem.withEventFields(item->Internal.castUnsafeEventItem, ~logger)
  | Block({blockNumber, onBlockRegistration}) =>
    logger->Logger.withFieldsJson(
      `{"onBlock":${JSON.stringify(
          JSON.String(onBlockRegistration.name),
        )},"block":${blockNumber->Int.toString}}`,
    )
  }

// `block` is the item's materialised selection, which already carries the key;
// without one the handler selected nothing but the key.
let makeOnBlockArgs = (
  ~blockNumber: int,
  ~block: option<Internal.eventBlock>,
  ~ecosystem: t,
  ~context,
): Internal.onBlockArgs => {
  switch ecosystem.name {
  | Svm => {slot: blockNumber, ?block, context}
  | Evm | Fuel =>
    let block = switch block {
    | Some(block) => block
    | None =>
      let keyOnly = Dict.make()
      keyOnly->Dict.set(ecosystem.blockNumberName, blockNumber->(Utils.magic: int => unknown))
      keyOnly->(Utils.magic: dict<unknown> => Internal.eventBlock)
    }
    {block, context}
  }
}
