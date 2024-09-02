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

type decodeEventLogError = EventNotFound | ParseError(exn)

let decodeEventLog: eventLog => result<
  decodedEvent<'a>,
  decodeEventLogError,
> = eventLog =>
  try {
    let decoded = eventLog->decodeEventLogUnsafe
    Ok(decoded)
  } catch {
  | exn => Error(ParseError(exn))
  }
