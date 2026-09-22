open Vitest

// What an operator reads while a supervised worker catches up: each of its
// chains says where it finished, and only then does the process say what it
// does about that.

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

let multichainYaml = name =>
  `
name: ${name}
disable_default_cross_chain: true
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:${chainYaml(1, "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3")}${chainYaml(
      137,
      "0x3B2f78c5BF6D9C12Ee1225D5F374aa91204580c3",
    )}`

// Rollback on, which is what gives a chain a reorg depth: held, it can only
// fetch as far as the safe block, and the release is what opens the rest up.
let rollbackScenario = Scenario.make(
  ~configYaml=multichainYaml("finalize-backfill-logging-rollback") ++ "\nrollback_on_reorg: true",
  ~schema,
  ~supervised=false,
)

// Rollback off, so a held chain has no reorg depth keeping it below the head:
// it indexes to the head, and a run resumed from what it stored has nothing
// left to fetch or process.
let headScenario = Scenario.make(
  ~configYaml=multichainYaml("finalize-backfill-logging") ++ "\nrollback_on_reorg: false",
  ~schema,
  ~supervised=false,
)

let singleChainScenario = Scenario.make(
  ~configYaml=`
name: finalize-backfill-logging-single-chain
disable_default_cross_chain: true
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:${chainYaml(1, "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3")}`,
  ~schema,
)

// The two lines this is about, in the order they were said.
let reportedFinishAndPause = (logs: array<IndexerRunner.logEntry>) =>
  logs
  ->Array.map(({msg}) => msg)
  ->Array.filter(msg =>
    msg->String.startsWith("Finished backfill") ||
      msg->String.startsWith("Building database indexes")
  )

let indexesMessage = "Building database indexes. Indexing is paused until they are ready, which can take a while on a large database."

describe("A supervised worker released at the head", () => {
  rollbackScenario->Scenario.it(
    "Says where each chain finished before saying it is building the indexes",
    ~sources=[{chain: 1}, {chain: 137}],
    ~holdRealtime=true,
    ~captureLogs=true,
    async (~t, ~indexer, ~source) => {
      let catchUpToSafeBlock = (~source: MockSource.t) => {
        source.resolveGetHeightOrThrow(300)
        source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      }
      catchUpToSafeBlock(~source=source(1))
      catchUpToSafeBlock(~source=source(137))
      await indexer.waitUntilIdle()

      indexer.releaseRealtime()
      await indexer.waitUntilIdle()

      source(1).resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      source(137).resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await indexer.waitUntilReady()

      t.expect((await indexer.logs())->reportedFinishAndPause).toStrictEqual([
        "Finished backfill. Waiting for the other chains.",
        "Finished backfill. Waiting for the other chains.",
        indexesMessage,
      ])
    },
  )
})

describe("A supervised worker resumed at the head", () => {
  // Its chains caught up in a run that was still held when it stopped, so the
  // resumed one owes the schema their indexes with no batch left to process.
  headScenario->Scenario.it(
    "Says where each chain finished before saying it is building the indexes",
    ~sources=[{chain: 1, autoHeight: 100}, {chain: 137, autoHeight: 100}],
    ~holdRealtime=true,
    ~captureLogs=true,
    async (~t, ~indexer, ~source) => {
      source(1).resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      source(137).resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.waitUntilIdle()

      let resumed = await indexer.restart()
      await resumed.waitUntilIdle()
      resumed.releaseRealtime()
      await resumed.waitUntilReady()

      t.expect((await resumed.logs())->reportedFinishAndPause).toStrictEqual([
        "Finished backfill. Waiting for the other chains.",
        "Finished backfill. Waiting for the other chains.",
        "Finished backfill. Waiting for the other chains.",
        "Finished backfill. Waiting for the other chains.",
        indexesMessage,
      ])
    },
  )
})

describe("A process driving one chain", () => {
  singleChainScenario->Scenario.it(
    "Names the chain it pauses in the singular",
    ~sources=[{chain: 1}],
    ~captureLogs=true,
    async (~t, ~indexer, ~source) => {
      source(1).resolveGetHeightOrThrow(100)
      source(1).resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.waitUntilReady()

      t.expect(
        (await indexer.logs())->Array.filter(({msg}) => msg === indexesMessage),
      ).toStrictEqual([{msg: indexesMessage, params: dict{"chainId": JSON.Number(1.)}}])
    },
  )
})
