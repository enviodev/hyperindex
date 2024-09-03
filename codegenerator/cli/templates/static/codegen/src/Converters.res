exception ParseError(Viem.decodeEventLogError)
exception UnregisteredContract(Address.t)

type eventModLookup = {
  sighash: string,
  contractAddress: Address.t,
  chainId: int,
}

exception EventModuleNotFound(eventModLookup)

let parseEvent = (
  ~log: Types.Log.t,
  ~eventModLookup: EventModLookup.t,
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
    switch eventModLookup->EventModLookup.get(
      ~sighash=log.topics[0],
      ~contractAddressMapping=contractInterfaceManager.contractAddressMapping,
      ~contractAddress=log.address,
    ) {
    | None =>
      Error(
        EventModuleNotFound({
          sighash: log.topics[0],
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
