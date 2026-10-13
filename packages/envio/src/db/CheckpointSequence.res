// How checkpoint ids are handed out. A schema with a cross-chain entity has
// rows any chain's reorg can reach, so its checkpoints have to be comparable
// across chains and come from one shared counter. Without one, no chain can
// touch another's rows, and each gets a counter of its own — which is what lets
// a rollback, a prune or a resume name one chain without saying anything about
// the others.
type t =
  | SharedAcrossChains
  | PerChain

let fromEntities = (entities: array<Internal.entityConfig>) =>
  entities->Array.some(entityConfig => entityConfig.crossChain) ? SharedAcrossChains : PerChain

// Where a chain stands: under one shared counter that is wherever the counter
// got to, whichever chain moved it last.
let position = (sequence: t, frontier: Frontier.t, ~chainId) =>
  switch sequence {
  | SharedAcrossChains => frontier->Frontier.max
  | PerChain => frontier->Frontier.get(chainId)
  }

// The committed (or processed) id a scope's rows compare against. A chain scope
// reads its own. A cross-chain scope spans every chain: under one shared
// sequence the highest id is exactly how far the scope has got, while per-chain
// ids aren't comparable across chains, so only the lowest is an id every chain
// has passed.
let forScope = (sequence: t, frontier: Frontier.t, ~scope: Internal.chainScope) =>
  switch scope {
  | Chain(chainId) => frontier->Frontier.get(chainId)
  | CrossChain =>
    switch sequence {
    | SharedAcrossChains => frontier->Frontier.max
    | PerChain => frontier->Frontier.min
    }
  }

// The diff id a scope's rows carry after a rollback, taken from the frontier the
// rollback stamped them with. A per-chain rollback names only the chains it
// moved: a sibling it left alone has no diff row, and so no id to compare
// against.
let findForScope = (sequence: t, frontier: Frontier.t, ~scope: Internal.chainScope): option<
  Internal.checkpointId,
> =>
  switch scope {
  | Chain(chainId) => frontier->Frontier.find(chainId)
  | CrossChain => Some(sequence->forScope(frontier, ~scope))
  }

// Hands out the ids of one batch, starting from where the frontier left each
// chain. Under `SharedAcrossChains` the ids come from a single run of the counter, so they
// interleave across chains in allocation order; under `PerChain` each chain
// continues its own.
type cursor = {sequence: t, frontier: Frontier.t}

let cursor = (sequence: t, ~frontier: Frontier.t) => {sequence, frontier: frontier->Frontier.copy}

let next = (cursor, ~chainId): Internal.checkpointId => {
  let checkpointId = cursor.sequence->position(cursor.frontier, ~chainId)->BigInt.add(1n)
  cursor.frontier->Frontier.set(chainId, checkpointId)
  checkpointId
}

// The checkpoint id each chain's rows are compared against in a query,
// together with the sequence that decides how the comparison is rendered.
type checkpointBoundsByChain = {sequence: t, byChain: Frontier.t}
