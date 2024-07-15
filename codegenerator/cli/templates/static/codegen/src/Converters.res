exception ParseError(Ethers.Interface.parseLogError)
exception UnregisteredContract(Ethers.ethAddress)

let makeEventLog = (
  params: 'args,
  ~log: Types.Log.t,
  ~transaction,
  ~block,
  ~chainId: int,
): Types.eventLog<Types.internalEventArgs> =>
  {
    chainId,
    params,
    transaction,
    block,
    srcAddress: log.address,
    logIndex: log.logIndex,
  }->Types.eventToInternal

let convertHyperSyncEvent = (
  event: HyperSyncClient.Decoder.decodedEvent,
  ~config,
  ~contractInterfaceManager,
  ~log: Types.Log.t,
  ~block,
  ~chainId,
  ~transaction,
): result<
  (
    Types.eventLog<Types.internalEventArgs>,
    module(Types.InternalEvent),
  ),
  _,
> => {
  switch contractInterfaceManager->ContractInterfaceManager.getContractNameFromAddress(
    ~contractAddress=log.address,
  ) {
  | None => Error(UnregisteredContract(log.address))
  | Some(contractName) =>
    let eventMod = config->Config.getEventModOrThrow(~contractName, ~topic0=log.topics[0])
    let module(Event) = eventMod
    let event =
      event
      ->Event.convertHyperSyncEventArgs
      ->makeEventLog(~log, ~transaction, ~block, ~chainId)
    Ok((event, eventMod))
  }
}

let parseEvent = (
  ~log: Types.Log.t,
  ~config,
  ~block,
  ~contractInterfaceManager,
  ~chainId,
  ~transaction,
): result<
  (
    Types.eventLog<Types.internalEventArgs>,
    module(Types.InternalEvent),
  ),
  _,
> => {
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
      let eventMod = config->Config.getEventModOrThrow(~contractName, ~topic0=log.topics[0])
      let event: Types.eventLog<Types.internalEventArgs> = {
        params: decodedEvent.args,
        chainId,
        transaction,
        block,
        srcAddress: log.address,
        logIndex: log.logIndex,
      }
      Ok(event, eventMod)
    }
  }
}
