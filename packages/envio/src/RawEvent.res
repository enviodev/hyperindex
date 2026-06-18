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

let make = (
  eventItem: Internal.eventItem,
  ~cleanUpRawEventFieldsInPlace: JSON.t => unit,
): Internal.rawEvent => {
  let {eventConfig, chain, blockNumber, blockHash, timestamp: blockTimestamp, payload} = eventItem
  let {block, transaction, params, logIndex, srcAddress} = payload->Internal.payloadToGenericEvent
  let chainId = chain->ChainMap.Chain.toChainId
  let eventId = EventUtils.packEventIndex(~logIndex, ~blockNumber)
  let blockFields =
    block
    ->(Utils.magic: Internal.eventBlock => option<dict<unknown>>)
    ->convertFieldsToJson
  let transactionFields =
    transaction
    ->(Utils.magic: Internal.eventTransaction => option<dict<unknown>>)
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
    chainId,
    eventId,
    eventName: eventConfig.name,
    contractName: eventConfig.contractName,
    blockNumber,
    logIndex,
    srcAddress,
    blockHash,
    blockTimestamp,
    blockFields,
    transactionFields,
    params,
  }
}
