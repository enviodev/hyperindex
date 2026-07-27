type name = | @as("evm") Evm | @as("fuel") Fuel | @as("svm") Svm

type t = {
  name: name,
  blockNumberName: string,
  blockTimestampName: string,
  blockHashName: string,
  cleanUpRawEventFieldsInPlace: JSON.t => unit,
  /** Method name that the block handler is exposed under on the public
      `indexer` object — `"onBlock"` for chain-based ecosystems, `"onSlot"`
      for SVM. Centralised here so adding a new ecosystem only requires a
      new ecosystem record, not another switch in `Main.res`. */
  onBlockMethodName: string,
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
      `LogSelection.res`. SVM does not support event handlers, so its
      schema always surfaces `None`. */
  onEventBlockFilterSchema: S.t<option<unknown>>,
  /** Materialise the user-facing event handed to handlers and contract
      registration from an item's opaque payload. `event.transaction` is written
      onto the payload at batch prep (HyperSync) or inline (RPC/simulate). */
  toEvent: Internal.eventItem => Internal.event,
  /** Log context fields for an event item, with ecosystem-specific keys
      (EVM/Fuel: contract/event/address; SVM: program/instruction/programId).
      Spread into every log line about the item. */
  toEventLogParams: Internal.eventItem => Internal.logParams,
  /** Build a raw event row for the `raw_events` table. Unsupported on SVM,
      where the implementation throws. */
  toRawEvent: Internal.eventItem => Internal.rawEvent,
}

// The materialised event is memoised on the item object — an item is processed
// across preload + execution passes.
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

let getItemLogParams = (item: Internal.item, ~ecosystem: t): Internal.logParams =>
  switch item {
  | Internal.Event(_) => ecosystem.toEventLogParams(item->Internal.castUnsafeEventItem)
  | Block({blockNumber, onBlockRegistration}) =>
    {
      "onBlock": onBlockRegistration.name,
      "chainId": onBlockRegistration.chainId,
      "block": blockNumber,
    }->Internal.toLogParams
  }

let getItemUserLogger = (item: Internal.item, ~ecosystem: t, ~logger: Pino.t): Envio.logger =>
  logger->Logging.userLogger(~params=getItemLogParams(item, ~ecosystem))

let makeOnBlockArgs = (~blockNumber: int, ~ecosystem: t, ~context): Internal.onBlockArgs => {
  switch ecosystem.name {
  | Svm => {slot: blockNumber, context}
  | _ => {
      let blockEvent = Dict.make()
      blockEvent->Dict.set(ecosystem.blockNumberName, blockNumber->(Utils.magic: int => unknown))
      {block: blockEvent->(Utils.magic: dict<unknown> => Internal.blockEvent), context}
    }
  }
}
