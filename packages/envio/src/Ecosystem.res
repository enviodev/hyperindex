type name = | @as("evm") Evm | @as("fuel") Fuel | @as("svm") Svm

type t = {
  name: name,
  blockFields: array<string>,
  transactionFields: array<string>,
  blockNumberName: string,
  blockTimestampName: string,
  blockHashName: string,
  getNumber: Internal.eventBlock => int,
  getTimestamp: Internal.eventBlock => int,
  getId: Internal.eventBlock => string,
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
}

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
