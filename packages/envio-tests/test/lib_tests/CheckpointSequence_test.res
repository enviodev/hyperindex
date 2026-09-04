open Vitest

// The rules a per-chain sequence turns on, pinned where they are decided rather
// than through the storage that reads them.

let chain1 = 1->ChainId.fromInt
let chain137 = 137->ChainId.fromInt

let frontier = Frontier.fromEntries([(chain1, 9n), (chain137, 2n)])

describe("CheckpointSequence.forScope", () => {
  it("Reads a chain scope's own id under either sequence", t => {
    t.expect((
      CheckpointSequence.Global->CheckpointSequence.forScope(frontier, ~scope=Chain(chain137)),
      CheckpointSequence.PerChain->CheckpointSequence.forScope(frontier, ~scope=Chain(chain137)),
    )).toEqual((2n, 2n))
  })

  // A cross-chain scope spans every chain. One shared counter orders every id,
  // so the highest is exactly how far the scope has got. Per-chain ids aren't
  // comparable across chains, so only the lowest is an id every chain has
  // passed — anything higher would count another chain's uncommitted work as
  // committed, and the effect caches this bounds would be freed early.
  it("Takes the highest id for a cross-chain scope under one shared sequence", t => {
    t.expect(
      CheckpointSequence.Global->CheckpointSequence.forScope(frontier, ~scope=CrossChain),
    ).toEqual(9n)
  })

  it("Takes the lowest id for a cross-chain scope where each chain counts its own", t => {
    t.expect(
      CheckpointSequence.PerChain->CheckpointSequence.forScope(frontier, ~scope=CrossChain),
    ).toEqual(2n)
  })

  it("Reads a chain the frontier doesn't name as having committed nothing", t => {
    t.expect(
      CheckpointSequence.PerChain->CheckpointSequence.forScope(
        frontier,
        ~scope=Chain(999->ChainId.fromInt),
      ),
    ).toEqual(Internal.initialCheckpointId)
  })
})

describe("CheckpointSequence.params", () => {
  // The two arrays are read positionally by the unnest relation, so a chain
  // paired with another chain's bound would narrow the wrong rows.
  it("Pairs each chain with its own id, in one order", t => {
    t.expect(
      CheckpointSequence.bounds(PerChain, frontier)
      ->CheckpointSequence.params
      ->(Utils.magic: unknown => array<array<unknown>>),
    ).toEqual([
      [chain1, chain137]->(Utils.magic: array<ChainId.t> => array<unknown>),
      ["9", "2"]->(Utils.magic: array<string> => array<unknown>),
    ])
  })

  // Every chain is held to one id under a shared sequence, and it has to be the
  // lowest: a higher one would leave another chain's rows above its own bound.
  it("Collapses to the lowest id under one shared sequence", t => {
    t.expect(
      CheckpointSequence.bounds(Global, frontier)
      ->CheckpointSequence.params
      ->(Utils.magic: unknown => array<string>),
    ).toEqual(["2"])
  })
})
