exception ParseError(Ethers.Interface.parseLogError)
exception UnregisteredContract(Address.t)

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

type eventLookup = {
  topic0: string,
  contractAddress: Address.t,
  chainId: int,
}

exception EventModuleNotFound(eventLookup)

let convertHyperSyncEvent = (
  event: HyperSyncClient.Decoder.decodedEvent,
  ~config,
  ~contractAddressMapping,
  ~log: Types.Log.t,
  ~block,
  ~chain,
  ~transaction,
): result<(Types.eventLog<Types.internalEventArgs>, module(Types.InternalEvent)), _> => {
  switch config.Config.events->EventLookup.getEvent(
    ~topic0=log.topics[0],
    ~chain,
    ~contractAddressMapping,
    ~contractAddress=log.address,
  ) {
  | None =>
    Error(
      EventModuleNotFound({
        topic0: log.topics[0],
        contractAddress: log.address,
        chainId: chain->ChainMap.Chain.toChainId,
      }),
    )
  | Some(eventMod) =>
    let module(Event) = eventMod
    let event =
      event
      ->Event.convertHyperSyncEventArgs
      ->makeEventLog(~log, ~transaction, ~block, ~chainId=chain->ChainMap.Chain.toChainId)
    Ok((event, eventMod))
  }
}

let parseEvent = (
  ~log: Types.Log.t,
  ~config,
  ~block,
  ~contractInterfaceManager,
  ~chain,
  ~transaction,
): result<(Types.eventLog<Types.internalEventArgs>, module(Types.InternalEvent)), _> => {
  let decodedEventResult = contractInterfaceManager->ContractInterfaceManager.parseLogViem(~log)
  switch decodedEventResult {
  | Error(e) =>
    switch e {
    | ParseError(parseError) => ParseError(parseError)
    | UndefinedInterface(contractAddress) => UnregisteredContract(contractAddress)
    }->Error

  | Ok(decodedEvent) =>
    switch config.Config.events->EventLookup.getEvent(
      ~topic0=log.topics[0],
      ~chain,
      ~contractAddressMapping=contractInterfaceManager.contractAddressMapping,
      ~contractAddress=log.address,
    ) {
    | None =>
      Error(
        EventModuleNotFound({
          topic0: log.topics[0],
          contractAddress: log.address,
          chainId: chain->ChainMap.Chain.toChainId,
        }),
      )
    | Some(eventMod) =>
      let module(Event) = eventMod
      let event: Types.eventLog<Types.internalEventArgs> = {
        params: decodedEvent.args,
        chainId: chain->ChainMap.Chain.toChainId,
        transaction,
        block,
        srcAddress: log.address,
        logIndex: log.logIndex,
      }
      Ok((event, eventMod))
    }
  }
}
