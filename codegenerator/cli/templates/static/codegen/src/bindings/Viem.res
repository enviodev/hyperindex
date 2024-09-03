type eventLog = {
  abi: Ethers.abi,
  data: string,
  topics: array<Ethers.EventFilter.topic>,
}

type decodedEvent<'a> = {
  eventName: string,
  args: 'a,
}

@module("viem") external decodeEventLogOrThrow: eventLog => decodedEvent<'a> = "decodeEventLog"
