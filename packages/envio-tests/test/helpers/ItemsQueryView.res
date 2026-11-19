// The queries by partition, each with its addresses in order.
module Summary = {
  type t = {
    partitionId: string,
    fromBlock: int,
    toBlock: MockSource.toBlock,
    addresses: array<string>,
  }

  let summarize = (queries: array<MockSource.pendingItemsQuery>) =>
    queries
    ->Array.map(query => {
      partitionId: query.partitionId,
      fromBlock: query.fromBlock,
      toBlock: query.toBlock,
      addresses: query
      ->MockSource.addresses
      ->Array.map(Address.toString)
      ->Array.toSorted(String.compare),
    })
    ->Array.toSorted((a, b) => String.compare(a.partitionId, b.partitionId))
}

// The queries in arrival order, with the contracts each fetches address-free.
module ClientFiltered = {
  type t = {
    partitionId: string,
    fromBlock: int,
    toBlock: MockSource.toBlock,
    addresses: array<string>,
    clientFilteredContracts: option<array<string>>,
  }

  let pendingQueries = (sourceMock: MockSource.t) =>
    sourceMock.pendingItemsQueries->Array.map(query => {
      partitionId: query.partitionId,
      fromBlock: query.fromBlock,
      toBlock: query.toBlock,
      addresses: query->MockSource.addresses->Array.map(Address.toString),
      clientFilteredContracts: (query->MockSource.selection).clientFilteredContracts,
    })
}
