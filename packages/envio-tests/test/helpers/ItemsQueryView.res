// The queries by what they ask for, each with its addresses in order.
module Summary = {
  type t = {
    fromBlock: int,
    toBlock: MockSource.toBlock,
    addresses: array<string>,
  }

  let toBlockOrder = (toBlock: MockSource.toBlock) =>
    switch toBlock {
    | Bounded(toBlock) => toBlock
    | Unbounded => Int.Constants.maxValue
    }

  let summarize = (queries: array<MockSource.pendingItemsQuery>) =>
    queries
    ->Array.map(query => {
      fromBlock: query.fromBlock,
      toBlock: query.toBlock,
      addresses: query
      ->MockSource.addresses
      ->Array.map(Address.toString)
      ->Array.toSorted(String.compare),
    })
    ->Array.toSorted((a, b) =>
      switch Int.compare(a.fromBlock, b.fromBlock) {
      | 0. =>
        switch Int.compare(a.toBlock->toBlockOrder, b.toBlock->toBlockOrder) {
        | 0. => String.compare(a.addresses->Array.join(","), b.addresses->Array.join(","))
        | order => order
        }
      | order => order
      }
    )
}

// The queries in arrival order, with the contracts each fetches address-free.
module AddressFree = {
  type t = {
    fromBlock: int,
    toBlock: MockSource.toBlock,
    addresses: array<string>,
    addressFreeContracts: array<string>,
  }

  let pendingQueries = (sourceMock: MockSource.t) =>
    sourceMock.pendingItemsQueries->Array.map(query => {
      fromBlock: query.fromBlock,
      toBlock: query.toBlock,
      addresses: query->MockSource.addresses->Array.map(Address.toString),
      addressFreeContracts: (query->MockSource.selection).addressFreeContracts,
    })
}
