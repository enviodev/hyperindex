open Vitest

// What a write keeps follows the schema's checkpoint sequence and, chain by
// chain, whether a rollback can still reach what that chain writes.
// `ChainState.keepsHistory` is what answers the latter — see ChainState_test.

let schema = `
type Counter {
  id: ID!
  count: BigInt!
}
`

let crossChainSchema =
  schema ++ `
type Total @crossChain {
  id: ID!
  count: BigInt!
}
`

let configYaml = (~extra="") =>
  `
name: history-policy
disable_default_cross_chain: true${extra}
contracts:
  - name: Counters
    events:
      - event: Bumped(uint256 amount)
chains:
  - id: 1
    start_block: 0
    max_reorg_depth: 200
    contracts:
      - name: Counters
        address: "0x1111111111111111111111111111111111111111"
  - id: 137
    start_block: 0
    max_reorg_depth: 200
    contracts:
      - name: Counters
        address: "0x1111111111111111111111111111111111111111"
`

let config = (~schema, ~extra="") =>
  InternalTestIndexer.fromUserApi(~configYaml=configYaml(~extra), ~schema).config

let chain1 = 1->ChainId.fromInt
let chain137 = 137->ChainId.fromInt

let keepsHistory = entries => {
  let dict = Dict.make()
  entries->Array.forEach(((chainId, keeps)) => dict->ChainId.Dict.set(chainId, keeps))
  dict
}

// Only chain 1 is still reachable by a rollback.
let onlyChain1 = keepsHistory([(chain1, true), (chain137, false)])

let decisions = (config: Config.t, ~keepsHistory) => {
  let policy = config->HistoryPolicy.decide(~keepsHistory)
  (policy->HistoryPolicy.forChain(chain1), policy->HistoryPolicy.forChain(chain137))
}

describe("HistoryPolicy", () => {
  // Each chain's rows are only reachable by its own rollback, so the chain
  // nothing can reach keeps nothing.
  it("Decides per chain when each chain counts its own checkpoints", t => {
    let config = config(~schema)
    t.expect((
      config.checkpointSequence,
      config->decisions(~keepsHistory=onlyChain1),
    )).toEqual((PerChain, (Keep, Skip)))
  })

  // One cross-chain entity makes any chain's rollback reach every chain's rows,
  // so the whole run keeps history as soon as one chain can be rolled back.
  it("Keeps every chain's rows once one chain's are reachable under a shared sequence", t => {
    let config = config(~schema=crossChainSchema)
    t.expect((
      config.checkpointSequence,
      config->decisions(~keepsHistory=onlyChain1),
    )).toEqual((Global, (Keep, Keep)))
  })

  it("Keeps nothing when no chain's rows are reachable", t => {
    t.expect((
      config(~schema)->decisions(
        ~keepsHistory=keepsHistory([(chain1, false), (chain137, false)]),
      ),
      config(~schema=crossChainSchema)->decisions(
        ~keepsHistory=keepsHistory([(chain1, false), (chain137, false)]),
      ),
    )).toEqual(((Skip, Skip), (Skip, Skip)))
  })

  it("Keeps everything with save_full_history, reachable or not", t => {
    t.expect(
      config(~schema, ~extra="\nsave_full_history: true")->decisions(
        ~keepsHistory=keepsHistory([(chain1, false), (chain137, false)]),
      ),
    ).toEqual((Keep, Keep))
  })

  // A cross-chain entity is what makes the sequence shared, so a cross-chain
  // group under per-chain sequences is a state the config can't produce.
  it("Refuses a cross-chain flush group under per-chain sequences", t => {
    let policy = config(~schema)->HistoryPolicy.decide(~keepsHistory=onlyChain1)
    t->toThrowErrorEqual(
      () => policy->HistoryPolicy.forScope(~scope=CrossChain),
      "Internal error: a cross-chain flush group can't exist under per-chain checkpoint sequences. A cross-chain entity is what makes the sequence shared.",
    )
  })

  it("Reads a chain scope's decision off the sequence it was built for", t => {
    let perChain = config(~schema)->HistoryPolicy.decide(~keepsHistory=onlyChain1)
    let shared = config(~schema=crossChainSchema)->HistoryPolicy.decide(~keepsHistory=onlyChain1)
    t.expect((
      perChain->HistoryPolicy.forScope(~scope=Chain(chain137)),
      shared->HistoryPolicy.forScope(~scope=Chain(chain137)),
      shared->HistoryPolicy.forScope(~scope=CrossChain),
    )).toEqual((Skip, Keep, Keep))
  })
})
