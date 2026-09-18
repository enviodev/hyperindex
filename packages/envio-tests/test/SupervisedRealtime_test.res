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
