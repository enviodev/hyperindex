open Vitest

// An indexer switches to realtime as a whole: every chain enters the reorg
// threshold together and every chain is stamped ready at one instant. A split
// run's processes each see only their own chains, so a supervised worker holds
// those transitions until the supervisor says every chain in the run has
// arrived.

let schema = `
type A {
  id: ID!
}
`

let chainYaml = (chainId, address) =>
  `
  - id: ${chainId->Int.toString}
    rpc:
      url: https://rpc${chainId->Int.toString}.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "${address}"
`

let endBlockScenario = Scenario.make(
  ~configYaml=`
name: supervised-realtime-end-block
disable_default_cross_chain: true
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:
  - id: 1
    rpc:
      url: https://rpc1.example.test
      for: sync
    start_block: 1
    end_block: 100
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"`,
  ~schema,
)

// Rollback on, which is what gives a chain a reorg depth: pre-threshold its
// fetch frontier is capped at the safe block, so progress can never reach the
// head until the chain enters the threshold.
let rollbackScenario = Scenario.make(
  ~configYaml=`
name: supervised-realtime-rollback
rollback_on_reorg: true
disable_default_cross_chain: true
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:${chainYaml(1, "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3")}${chainYaml(
      137,
      "0x3B2f78c5BF6D9C12Ee1225D5F374aa91204580c3",
    )}`,
  ~schema,
)

let scenario = Scenario.make(
  ~configYaml=`
name: supervised-realtime
disable_default_cross_chain: true
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:${chainYaml(1, "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3")}${chainYaml(
      137,
      "0x3B2f78c5BF6D9C12Ee1225D5F374aa91204580c3",
    )}`,
  ~schema,
)

let readyAtByChainId = async (~sql, ~pgSchema) => {
  let rows: array<{
    "id": ChainId.t,
    "ready_at": Null.t<Date.t>,
  }> = await sql->Postgres.unsafe(
    `SELECT "id", "ready_at" FROM "${pgSchema}"."envio_chains" ORDER BY "id";`,
  )
  rows->Array.map(row => (row["id"]->ChainId.toString, row["ready_at"]->Null.toOption))
}

let catchUp = (~source: MockSource.t) => {
  source.resolveGetHeightOrThrow(100)
  source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
}

describe("A supervised worker", () => {
  scenario->Scenario.it(
    "Waits for the run before going realtime, then stamps every chain at one instant",
    ~sources=[{chain: 1}, {chain: 137}],
    ~holdRealtime=true,
    async (~t, ~indexer, ~source) => {
      let {sql, pgSchema} = indexer.pg
      catchUp(~source=source(1))
      catchUp(~source=source(137))
      await indexer.waitUntilIdle()

      t.expect(
        (await readyAtByChainId(~sql, ~pgSchema), await indexer.metric("envio_progress_ready")),
        ~message="Both chains are at the head, but the run has not said so",
      ).toEqual((
        [("1", None), ("137", None)],
        [{value: "0", labels: dict{"chainId": "1"}}, {value: "0", labels: dict{"chainId": "137"}}],
      ))

      indexer.releaseRealtime()
      await indexer.waitUntilReady()

      let readyAt = await readyAtByChainId(~sql, ~pgSchema)
      let stamps = readyAt->Array.filterMap(((_, at)) => at->Option.map(Date.getTime))
      t.expect(
        (readyAt->Array.map(((chainId, _)) => chainId), stamps->Array.length, stamps->Set.fromArray->Set.size),
        ~message="The release stamps every chain, and one caught-up indexer is one instant",
      ).toEqual((["1", "137"], 2, 1))
    },
  )
})

describe("A supervised worker at its end block", () => {
  let exited = ref(false)

  endBlockScenario->Scenario.it(
    "Stays for the run rather than exiting with the indexes it still owes",
    ~sources=[{chain: 1}],
    ~holdRealtime=true,
    async (~t, ~indexer, ~source) => {
      let {sql, pgSchema} = indexer.pg
      catchUp(~source=source(1))
      await indexer.getBatchWritePromise()
      await indexer.waitUntilIdle()

      t.expect(
        (exited.contents, await readyAtByChainId(~sql, ~pgSchema)),
        ~message="Its chain is done, but it still owes the schema the indexes it deferred",
      ).toEqual((false, [("1", None)]))

      indexer.releaseRealtime()
      await indexer.waitUntilReady()

      t.expect(
        (await readyAtByChainId(~sql, ~pgSchema))->Array.map(((chainId, readyAt)) => (
          chainId,
          readyAt->Option.isSome,
        )),
        ~message="Released, it finalizes and stamps its chain",
      ).toEqual([("1", true)])
    },
    ~onExit=() => exited := true,
  )
})

describe("A run whose chains have a reorg depth", () => {
  // The transition the barrier holds is the one that lifts the pre-threshold
  // lag. Held until its chains reach the head, a run would be waiting on
  // progress only that transition makes reachable — so what a worker reports
  // as arrived has to be the safe block, as far as it can fetch until then.
  rollbackScenario->Scenario.it(
    "Enters the reorg threshold once every chain is at its safe block",
    ~sources=[{chain: 1}, {chain: 137}],
    async (~t, ~indexer, ~source) => {
      await Scenario.enterReorgThreshold(~t, ~indexer, ~source=source(1))
      await Scenario.enterReorgThreshold(~t, ~indexer, ~source=source(137))

      t.expect(
        await indexer.metric("envio_reorg_threshold"),
        ~message="Both chains have fetched the whole finalized range",
      ).toEqual([{value: "1", labels: Dict.make()}])
    },
  )
})

describe("A supervised worker on a chain with a reorg depth", () => {
  // The transition being held is the one that lifts the pre-threshold lag, so a
  // run held until its chains reach the head would be waiting on progress that
  // only the transition itself makes reachable.
  rollbackScenario->Scenario.it(
    "Arrives at the safe block, which is as far as it can fetch before the threshold",
    ~sources=[{chain: 1}, {chain: 137}],
    ~holdRealtime=true,
    async (~t, ~indexer, ~source) => {
      let {sql, pgSchema} = indexer.pg
      let head = 300
      // A response short of the head by the reorg depth: the whole finalized
      // range, and all this chain may fetch until it enters the threshold.
      let catchUpToSafeBlock = (~source: MockSource.t) => {
        source.resolveGetHeightOrThrow(head)
        source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=head - 200)
      }
      catchUpToSafeBlock(~source=source(1))
      catchUpToSafeBlock(~source=source(137))
      await indexer.waitUntilIdle()

      t.expect(
        await readyAtByChainId(~sql, ~pgSchema),
        ~message="Both chains are as far as they can fetch, and the run has not said so",
      ).toEqual([("1", None), ("137", None)])

      indexer.releaseRealtime()
      await indexer.waitUntilReady()

      t.expect(
        (await readyAtByChainId(~sql, ~pgSchema))->Array.map(((chainId, readyAt)) => (
          chainId,
          readyAt->Option.isSome,
        )),
        ~message="Released, the run enters the threshold and stamps its chains",
      ).toEqual([("1", true), ("137", true)])
    },
  )
})
