open Vitest

let incrementAt = block =>
  Indexer.makeSimulateItem(OnEvent({event: Counter(Increment), block: {number: block}}))

// Both chains increment the same "singleton" Counter id. In isolated multichain
// mode each chain keeps its own row (composite (id, chain_id) key), so the
// per-chain counts never merge: chain 1 sees 3 increments, chain 137 sees 2.
Async.it("Isolated multichain keeps the same entity id separate per chain", async t => {
  let indexer = Indexer.createTestIndexer()

  let _ = await indexer.process({
    chains: {
      \"1": {startBlock: 0, endBlock: 10, simulate: [incrementAt(1), incrementAt(2), incrementAt(3)]},
      \"137": {startBlock: 0, endBlock: 10, simulate: [incrementAt(1), incrementAt(2)]},
    },
  })

  // Each row carries the chain id it belongs to (the isolated chain id column),
  // so the same "singleton" id resolves to two independent rows.
  let counters =
    (await indexer.\"Counter".getAll())
    ->(
      Obj.magic: array<Indexer.Entities.Counter.t> => array<{
        "id": string,
        "count": int,
        "chainId": int,
      }>
    )
    ->Array.toSorted((a, b) => Int.compare(a["count"], b["count"]))

  t.expect(counters).toEqual([
    {"id": "singleton", "count": 2, "chainId": 137},
    {"id": "singleton", "count": 3, "chainId": 1},
  ])
})
