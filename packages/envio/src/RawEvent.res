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

// Block and transaction are passed already extracted from the ecosystem's
// concrete payload (EVM or Fuel) — `RawEvent` stays payload-shape-agnostic and
// only needs them as opaque field bags to serialise. The dedicated
// `block_hash`/`block_timestamp` column values are extracted from the payload
// block by the ecosystem caller (the field names differ per ecosystem).
let make = (
  eventItem: Internal.eventItem,
  ~block,
  ~transaction,
  ~params: Internal.eventParams,
  ~srcAddress: Address.t,
  ~blockHash: string,
  ~blockTimestamp: int,
  ~cleanUpRawEventFieldsInPlace: JSON.t => unit,
): Internal.rawEvent => {
  let {onEventRegistration, chain, blockNumber, logIndex} = eventItem
  let eventConfig = onEventRegistration.eventConfig
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

  // Serialize to unknown, because serializing to Js.Json.t fails for Bytes Fuel type, since it has unknown schema
  let params =
    params
    ->S.reverseConvertOrThrow(eventConfig.paramsRawEventSchema)
    ->(Utils.magic: unknown => JSON.t)
  let params = if params === %raw(`null`) {
    // Should probably make the params field nullable
    // But this is currently needed to make events
    // with empty params work
    %raw(`"null"`)
  } else {
    params
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
