let convertFieldsToJson = (fields: option<dict<unknown>>) => {
  switch fields {
  | None => %raw(`{}`)
  | Some(fields) =>
    // Convert bigint fields to string. There are no fields with nested
    // bigints, so iterating only the top level is safe.
    fields
    ->Utils.Dict.mapValues(value =>
      typeof(value) === #bigint
        ? value
          ->(Utils.magic: unknown => bigint)
          ->BigInt.toString
          ->(Utils.magic: string => unknown)
        : value
    )
    ->(Utils.magic: dict<unknown> => JSON.t)
  }
}

// Zero-parameter events decode to an empty object, which the params schema is
// built to reject (it expects no params at all). They carry no data to store,
// so they're detected here and short-circuited to the "null" sentinel.
let isEmptyParams = (params: Internal.eventParams): bool => {
  let raw = params->(Utils.magic: Internal.eventParams => unknown)
  typeof(raw) === #object &&
  raw !== %raw(`null`) &&
  raw->(Utils.magic: unknown => dict<unknown>)->Dict.keysToArray->Array.length == 0
}

// Block and transaction are passed already extracted from the ecosystem's
// concrete payload (EVM or Fuel) — `RawEvent` stays payload-shape-agnostic and
// only needs them as opaque field bags to serialise.
let make = (
  eventItem: Internal.eventItem,
  ~block,
  ~transaction,
  ~params: Internal.eventParams,
  ~srcAddress: Address.t,
  ~cleanUpRawEventFieldsInPlace: JSON.t => unit,
): Internal.rawEvent => {
  let {eventConfig, chain, blockNumber, blockHash, timestamp: blockTimestamp, logIndex} = eventItem
  let chainId = chain->ChainMap.Chain.toChainId
  let eventId = EventUtils.packEventIndex(~logIndex, ~blockNumber)
  let blockFields =
    block
    ->(Utils.magic: 'block => option<dict<unknown>>)
    ->convertFieldsToJson
  let transactionFields =
    transaction
    ->(Utils.magic: 'transaction => option<dict<unknown>>)
    ->convertFieldsToJson

  blockFields->cleanUpRawEventFieldsInPlace

  // Should probably make the params field nullable, but the "null" sentinel is
  // currently needed to make events with empty params work.
  let params = if params->isEmptyParams {
    %raw(`"null"`)
  } else {
    // Serialize to unknown, because serializing to Js.Json.t fails for Bytes Fuel type, since it has unknown schema
    let params =
      params
      ->S.reverseConvertOrThrow(eventConfig.paramsRawEventSchema)
      ->(Utils.magic: unknown => JSON.t)
    params === %raw(`null`) ? %raw(`"null"`) : params
  }

  {
    chain_id: chainId,
    event_id: eventId,
    event_name: eventConfig.name,
    contract_name: eventConfig.contractName,
    block_number: blockNumber,
    log_index: logIndex,
    src_address: srcAddress,
    block_hash: blockHash,
    block_timestamp: blockTimestamp,
    block_fields: blockFields,
    transaction_fields: transactionFields,
    params,
  }
}
