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
  cleanUpRawEventFieldsInPlace: Js.Json.t => unit,
  /** Method name that the block handler is exposed under on the public
      `indexer` object — `"onBlock"` for chain-based ecosystems, `"onSlot"`
      for SVM. Centralised here so adding a new ecosystem only requires a
      new ecosystem record, not another switch in `Main.res`. */
  onBlockMethodName: string,
  /** Extracts the inner `{_gte?, _lte?, _every?}` triple from the user's
      `where` return value. Each ecosystem's `indexer.onBlock`/`onSlot`
      filter shape differs (`block.number` on EVM, `block.height` on Fuel,
      `slot` on SVM), so the unwrap is ecosystem-specific. The returned
      `unknown` is then casted to the typed range record by `Main.res`. */
  extractOnBlockNumberFilter: unknown => option<unknown>,
}

let makeOnBlockArgs = (~blockNumber: int, ~ecosystem: t, ~context): Internal.onBlockArgs => {
  switch ecosystem.name {
  | Svm => {slot: blockNumber, context}
  | _ => {
      let blockEvent = Js.Dict.empty()
      blockEvent->Js.Dict.set(ecosystem.blockNumberName, blockNumber->(Utils.magic: int => unknown))
      {block: blockEvent->(Utils.magic: Js.Dict.t<unknown> => Internal.blockEvent), context}
    }
  }
}
