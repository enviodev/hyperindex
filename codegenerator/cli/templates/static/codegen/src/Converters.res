exception ParseError(Ethers.Interface.parseLogError)
exception UnregisteredContract(Ethers.ethAddress)

let makeEventLog = (
  params: 'args,
  ~log: Types.Log.t,
  ~transaction,
  ~block,
  ~chainId: int,
): Types.eventLog<Types.internalEventArgs> => {
  chainId,
  params,
  transaction,
  block,
  srcAddress: log.address,
  logIndex: log.logIndex,
}->Types.eventToInternal

let convertDecodedEvent = (
  event: HyperSyncClient.Decoder.decodedEvent,
  ~contractInterfaceManager,
  ~log: Types.Log.t,
  ~block,
  ~chainId,
  ~transaction,
): result<(Types.eventLog<Types.internalEventArgs>, module(Types.Event with type eventArgs = Types.internalEventArgs)), _> => {
  switch contractInterfaceManager->ContractInterfaceManager.getContractNameFromAddress(
    ~contractAddress=log.address,
  ) {
  | None => Error(UnregisteredContract(log.address))
  | Some(contractName) =>
    let eventMod = Types.eventTopicToEventMod(contractName, log.topics[0])
    let module(Event) = eventMod
    let event = event
      ->Event.convertDecodedEventParams
      ->makeEventLog(~log, ~transaction, ~block, ~chainId)
    Ok((event, eventMod))
  }
}

let parseEvent = (
  ~log: Types.Log.t,
  ~block,
  ~contractInterfaceManager,
  ~chainId,
  ~transaction,
): result<(Types.eventLog<Types.internalEventArgs>, module(Types.Event with type eventArgs = Types.internalEventArgs)), _> => {
 let decodedEventResult = contractInterfaceManager->ContractInterfaceManager.parseLogViem(~log)
  switch decodedEventResult {
  | Error(e) =>
    switch e {
    | ParseError(parseError) => ParseError(parseError)
    | UndefinedInterface(contractAddress) => UnregisteredContract(contractAddress)
    }->Error

  | Ok(decodedEvent) =>
    switch contractInterfaceManager->ContractInterfaceManager.getContractNameFromAddress(
      ~contractAddress=log.address,
    ) {
    | None => Error(UnregisteredContract(log.address))
    | Some(contractName) =>
      let eventMod = Types.eventNameToEventMod(decodedEvent.eventName, contractName)
      let module(Event) = eventMod
      let event = decodedEvent->Event.convertLogViem(~log, ~transaction, ~block, ~chainId)
      Ok(event, eventMod)
    }
  }
}

let blockFromRawEvent = (
  _rawEvent: TablesStatic.RawEvents.t,
  _selectableBlockFields: Types.Block.selectableFields,
): Types.Block.t =>
  %raw(`
  {
    number: _rawEvent.block_number,
    timestamp: _rawEvent.block_timestamp,
    hash: _rawEvent.block_hash,
    ..._selectableBlockFields
  }
`)

let decodeRawEventWith = (
  rawEvent: TablesStatic.RawEvents.t,
  ~eventMod: module(Types.Event with type eventArgs = Types.internalEventArgs),
  ~chain,
): result<Types.eventBatchQueueItem, S.error> => {
  let module(Event) = eventMod
  let parsedParams = rawEvent.params->S.parseWith(Event.eventArgsSchema)
  let parsedTransactionFields = rawEvent.transactionFields->S.parseWith(Types.Transaction.schema)
  let parsedSelectableBlockFields = rawEvent.blockFields->S.parseWith(Types.Block.schema)

  switch (parsedParams, parsedTransactionFields, parsedSelectableBlockFields) {
  | (Ok(params), Ok(transaction), Ok(selectableBlockFields)) =>
    let block = rawEvent->blockFromRawEvent(selectableBlockFields)

    let queueItem: Types.eventBatchQueueItem = {
      event: {
        chainId: rawEvent.chainId,
        transaction,
        block,
        srcAddress: rawEvent.srcAddress,
        logIndex: rawEvent.logIndex,
        params,
      },
      eventMod,
      timestamp: rawEvent.blockTimestamp,
      chain,
      blockNumber: rawEvent.blockNumber,
      logIndex: rawEvent.logIndex,
    }

    Ok(queueItem)
  | (Error(err), _, _) | (_, Error(err), _) | (_, _, Error(err)) => Error(err)
  }
}

let parseRawEvent = (rawEvent: TablesStatic.RawEvents.t, ~chain): result<
  Types.eventBatchQueueItem,
  S.error,
> => {
  let eventMod = rawEvent.eventType->Types.eventTypeToEventMod
  rawEvent->decodeRawEventWith(
    ~eventMod,
    ~chain,
  )
}
