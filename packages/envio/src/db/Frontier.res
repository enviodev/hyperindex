// Where each chain stands in its checkpoint sequence.
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

// Whether the frontier names the chain at all, as opposed to `get`'s reading of
// an absent chain as the initial id. A rollback frontier names only the chains
// it moved, and "no id" is not the same answer as "id zero" there.
let find = (frontier: t, chainId): option<Internal.checkpointId> =>
  frontier->ChainId.Dict.dangerouslyGetNonOption(chainId)

let set = (frontier: t, chainId, checkpointId) => frontier->ChainId.Dict.set(chainId, checkpointId)

let chainIds = (frontier: t): array<ChainId.t> =>
  frontier->Dict.keysToArray->Array.map(ChainId.normalizeOrThrow)

let entries = (frontier: t): array<(ChainId.t, Internal.checkpointId)> =>
  frontier
  ->Dict.toArray
  ->Array.map(((key, checkpointId)) => (key->ChainId.normalizeOrThrow, checkpointId))

// The two parallel arrays an `unnest($1, $2) AS ...(chain_id, checkpoint_id)`
// relation reads positionally.
type unnestParams = (array<ChainId.t>, array<string>)

let unnestParams = (frontier: t): unnestParams => {
  let chainIds = []
  let checkpointIds = []
  frontier->Utils.Dict.forEachWithKey((checkpointId, key) => {
    chainIds->Array.push(key->ChainId.normalizeOrThrow)
    checkpointIds->Array.push(checkpointId->BigInt.toString)
  })
  (chainIds, checkpointIds)
}

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
