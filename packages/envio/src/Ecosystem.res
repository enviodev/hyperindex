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
}

let makeOnBlockArgs = (~blockNumber: int, ~ecosystem: t, ~context): Internal.onBlockArgs => {
  switch ecosystem.name {
  | Svm => {slot: blockNumber, context}
  | _ => {
      let blockEvent = Js.Dict.empty()
      blockEvent->Js.Dict.set(ecosystem.blockNumberName, blockNumber->(Utils.magic: int => unknown))
      let rawBlock = blockEvent->(Utils.magic: Js.Dict.t<unknown> => Internal.blockEvent)
      // Block handlers only support the block number field;
      // all other fields throw a friendly error guiding the user to request support.
      let proxiedBlock = FieldSelection.makeBlockHandlerProxy(rawBlock)
      {block: proxiedBlock->(Utils.magic: FieldSelection.proxy<Internal.blockEvent> => Internal.blockEvent), context}
    }
  }
}
