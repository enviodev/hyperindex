type eventLog = {
  abi: Ethers.abi,
  data: string,
  topics: array<Ethers.EventFilter.topic>,
}

type decodedEvent<'a> = {
  eventName: string,
  args: 'a,
}

@module("viem") external decodeEventLogUnsafe: eventLog => decodedEvent<'a> = "decodeEventLog"

let decodeEventLog: eventLog => result<
  decodedEvent<'a>,
  Ethers.Interface.parseLogError,
> = eventLog =>
  try {
    let decoded = eventLog->decodeEventLogUnsafe
    Ok(decoded)
  } catch {
  | exn => Error(ParseError(exn))
  }

@module("viem") external getAddressUnsafe: string => Address.t = "getAddress"

let getAddress = s =>
  switch getAddressUnsafe(s) {
  | exception exn => Error(exn)
  | addr => Ok(addr)
  }
