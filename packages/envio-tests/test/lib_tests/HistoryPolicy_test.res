open Vitest

// What a write keeps is decided per flush group, from the chain states, and
// then carried — so the two things that can differ between groups are the
// chain's own reorg threshold and its own reorg depth.

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

let configYaml = (~laggingMaxReorgDepth, ~extra="") =>
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
    max_reorg_depth: ${laggingMaxReorgDepth->Int.toString}
    contracts:
      - name: Counters
        address: "0x1111111111111111111111111111111111111111"
`

let config = (~schema, ~laggingMaxReorgDepth=200, ~extra="") =>
  InternalTestIndexer.fromUserApi(
    ~configYaml=configYaml(~laggingMaxReorgDepth, ~extra),
    ~schema,
  ).config

let chain1 = 1->ChainId.fromInt
let chain137 = 137->ChainId.fromInt

// Chain 1 is inside its reorg threshold, chain 137 is still below it.
let onlyChain1InThreshold = chainId => chainId === chain1

let decisions = (config: Config.t, ~isChainInReorgThreshold) => {
  let isInReorgThreshold = isChainInReorgThreshold(chain1) || isChainInReorgThreshold(chain137)
  let forScope = scope =>
    config->HistoryPolicy.forScope(~scope, ~isInReorgThreshold, ~isChainInReorgThreshold)
  (
    config->HistoryPolicy.forBatch(~isInReorgThreshold),
    forScope(Chain(chain1)),
    forScope(Chain(chain137)),
  )
}

describe("HistoryPolicy", () => {
  // Each chain's rows are only reachable by its own rollback, so the chain
  // still below its threshold keeps nothing.
  it("Keeps only the chains past their own threshold under per-chain sequences", t => {
    let config = config(~schema)
    t.expect((
      config.checkpointSequence,
      config->decisions(~isChainInReorgThreshold=onlyChain1InThreshold),
    )).toEqual((PerChain, (Keep, Keep, Skip)))
  })

  // One cross-chain entity makes any chain's rollback reach every chain's rows,
  // so the whole run keeps history as soon as one chain can be rolled back.
  it("Keeps every chain's rows once any chain is past its threshold under a shared sequence", t => {
    let config = config(~schema=crossChainSchema)
    t.expect((
      config.checkpointSequence,
      config->decisions(~isChainInReorgThreshold=onlyChain1InThreshold),
    )).toEqual((Global, (Keep, Keep, Keep)))
  })

  // A chain that can't be rolled back has no history to keep — unless a
  // cross-chain entity lets a sibling's rollback reach its rows.
  it("Skips a chain with no reorg depth even inside the threshold", t => {
    t.expect((
      config(~schema, ~laggingMaxReorgDepth=0)->decisions(~isChainInReorgThreshold=_ => true),
      config(~schema=crossChainSchema, ~laggingMaxReorgDepth=0)->decisions(
        ~isChainInReorgThreshold=_ => true,
      ),
    )).toEqual(((Keep, Keep, Skip), (Keep, Keep, Keep)))
  })

  it("Keeps everything with save_full_history, threshold or not", t => {
    t.expect(
      config(~schema, ~laggingMaxReorgDepth=0, ~extra="\nsave_full_history: true")->decisions(
        ~isChainInReorgThreshold=_ => false,
      ),
    ).toEqual((Keep, Keep, Keep))
  })

  it("Keeps nothing when the run can't roll back at all", t => {
    t.expect(
      config(~schema, ~extra="\nrollback_on_reorg: false")->decisions(
        ~isChainInReorgThreshold=_ => true,
      ),
    ).toEqual((Skip, Skip, Skip))
  })

  // A cross-chain entity is what makes the sequence shared, so a cross-chain
  // group under per-chain sequences is a state the config can't produce.
  it("Refuses a cross-chain flush group under per-chain sequences", t => {
    t->toThrowErrorEqual(
      () =>
        config(~schema)->HistoryPolicy.forScope(
          ~scope=CrossChain,
          ~isInReorgThreshold=true,
          ~isChainInReorgThreshold=_ => true,
        ),
      "Internal error: a cross-chain flush group can't exist under per-chain checkpoint sequences. A cross-chain entity is what makes the sequence shared.",
    )
  })
})
