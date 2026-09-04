// Where each chain stands in its checkpoint sequence: one id per chain, always.
// Committed and processed progress, resume state, prune bounds and rollback
// floors are all this shape, so nothing downstream has to ask whether a
// position is one id or many.
type t = dict<Internal.checkpointId>

let empty = (): t => Dict.make()

let make = (~chainIds: array<ChainId.t>, ~checkpointId): t => {
  let frontier = Dict.make()
  chainIds->Array.forEach(chainId => frontier->ChainId.Dict.set(chainId, checkpointId))
  frontier
}

let fromEntries = (entries: array<(ChainId.t, Internal.checkpointId)>): t => {
  let frontier = Dict.make()
  entries->Array.forEach(((chainId, checkpointId)) =>
    frontier->ChainId.Dict.set(chainId, checkpointId)
  )
  frontier
}

let copy = (frontier: t): t => frontier->Dict.copy

// A chain the frontier doesn't name has committed nothing yet, which is what
// the initial checkpoint id means.
let get = (frontier: t, chainId): Internal.checkpointId =>
  switch frontier->ChainId.Dict.dangerouslyGetNonOption(chainId) {
  | Some(checkpointId) => checkpointId
  | None => Internal.initialCheckpointId
  }

let set = (frontier: t, chainId, checkpointId) => frontier->ChainId.Dict.set(chainId, checkpointId)

// A dict key is the chain id's decimal string, which is the same key a chain id
// indexes by — but it is not the id itself, and these hand ids back to callers
// that compare and encode them rather than only look them up.
let chainIds = (frontier: t): array<ChainId.t> =>
  frontier->Dict.keysToArray->Array.map(ChainId.normalizeOrThrow)

let entries = (frontier: t): array<(ChainId.t, Internal.checkpointId)> =>
  frontier
  ->Dict.toArray
  ->Array.map(((key, checkpointId)) => (key->ChainId.normalizeOrThrow, checkpointId))

%%private(
  let fold = (frontier: t, pick) =>
    frontier
    ->Dict.valuesToArray
    ->Array.reduce(None, (acc, checkpointId) =>
      switch acc {
      | None => Some(checkpointId)
      | Some(picked) => Some(pick(picked, checkpointId))
      }
    )
)

// A frontier naming no chain has committed nothing anywhere.
let max = (frontier: t) =>
  frontier->fold(Pervasives.max)->Option.getOr(Internal.initialCheckpointId)
let min = (frontier: t) =>
  frontier->fold(Pervasives.min)->Option.getOr(Internal.initialCheckpointId)

// Combines two frontiers chain by chain, keeping every chain either names.
%%private(
  let merge = (a: t, b: t, pick) => {
    let merged = a->copy
    b->Utils.Dict.forEachWithKey((checkpointId, key) =>
      merged->Dict.set(
        key,
        switch merged->Utils.Dict.dangerouslyGetNonOption(key) {
        | Some(existing) => pick(existing, checkpointId)
        | None => checkpointId
        },
      )
    )
    merged
  }
)

// The frontier restricted to the named chains, dropping every other entry.
let pick = (frontier: t, ~chainIds: array<ChainId.t>): t =>
  chainIds->Array.map(chainId => (chainId, frontier->get(chainId)))->fromEntries

let mergeMin = (a: t, b: t) => merge(a, b, Pervasives.min)
let mergeMax = (a: t, b: t) => merge(a, b, Pervasives.max)

let equals = (a: t, b: t) => {
  let same = (a: t, b: t) =>
    a
    ->Dict.toArray
    ->Array.every(((key, checkpointId)) =>
      switch b->Utils.Dict.dangerouslyGetNonOption(key) {
      | Some(other) => other == checkpointId
      | None => checkpointId == Internal.initialCheckpointId
      }
    )
  same(a, b) && same(b, a)
}
