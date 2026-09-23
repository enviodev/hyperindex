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

      t.expect(
        indexer.logs()->reportedFinishAndPause,
        ~message="Released, nothing holds the process back, and its chains finish together",
      ).toStrictEqual(["Finished backfill.", "Finished backfill.", indexesMessage])
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

      t.expect(
        resumed.logs()->reportedFinishAndPause,
        ~message="Both runs' chains speak while the hold is on, so both runs say they are waiting",
      ).toStrictEqual([
        "Finished backfill. Waiting for the other chains.",
        "Finished backfill. Waiting for the other chains.",
        "Finished backfill. Waiting for the other chains.",
        "Finished backfill. Waiting for the other chains.",
        indexesMessage,
      ])
    },
  )
})

describe("A chain resumed already ready", () => {
  // It didn't backfill in this run and owes the schema nothing, so it has
  // nothing to announce — the resume already said where indexing continues
  // from. Only a chain that gets there while this run watches says so.
  headScenario->Scenario.it(
    "Says nothing about a backfill it didn't do",
    ~sources=[{chain: 1, autoHeight: 100}, {chain: 137, autoHeight: 100}],
    ~captureLogs=true,
    async (~t, ~indexer, ~source) => {
      source(1).resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      source(137).resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.waitUntilReady()

      // New blocks on both chains, so the resumed run indexes at the head
      // rather than sitting idle with nothing to say.
      source(1).setAutoHeight(110)
      source(137).setAutoHeight(110)
      let resumed = await indexer.restart()
      source(1).resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=110)
      source(137).resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=110)
      await resumed.getBatchWritePromise()

      t.expect(
        resumed.logs()->reportedFinishAndPause,
        ~message="Both chains caught up and were stamped ready in the first run, and the resumed one repeats neither",
      ).toStrictEqual(["Finished backfill.", "Finished backfill.", indexesMessage])
    },
  )
})

let endBlockScenario = Scenario.make(
  ~configYaml=`
name: finalize-backfill-logging-end-block
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

describe("A chain resumed already at its end block", () => {
  // Unlike a finished backfill, being done is still true on the resume, and it
  // is what explains a run that exits as soon as it starts.
  endBlockScenario->Scenario.it(
    "Says it is done again, before the resumed run exits",
    ~sources=[{chain: 1, autoHeight: 100}],
    ~captureLogs=true,
    ~onExit=() => (),
    async (~t, ~indexer, ~source) => {
      source(1).resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.waitUntilReady()

      let resumed = await indexer.restart()
      await resumed.waitUntilIdle()

      t.expect(
        resumed.logs()->Array.filter(({msg}) =>
          msg === "Indexed to the end block. This chain is done."
        ),
        ~message="Said once by each run",
      ).toStrictEqual([
        {
          msg: "Indexed to the end block. This chain is done.",
          params: dict{"chainId": JSON.Number(1.), "block": JSON.Number(100.)},
        },
        {
          msg: "Indexed to the end block. This chain is done.",
          params: dict{"chainId": JSON.Number(1.), "block": JSON.Number(100.)},
        },
      ])
    },
  )
})

let finishLines = (logs: array<IndexerRunner.logEntry>) =>
  logs->Array.filter(({msg}) => msg->String.startsWith("Finished backfill"))

describe("A process whose chains finish at different times", () => {
  // Waiting is said only while it is true: the chain that finishes first waits
  // on the one still behind, and the last one in waits on nobody.
  headScenario->Scenario.it(
    "Says it is waiting only while another chain is still behind",
    ~sources=[{chain: 1, autoHeight: 100}, {chain: 137, autoHeight: 100}],
    ~captureLogs=true,
    async (~t, ~indexer, ~source) => {
      source(1).resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      source(137).resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=50)
      await indexer.getBatchWritePromise()
      source(137).resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.waitUntilReady()

      t.expect(indexer.logs()->finishLines).toStrictEqual([
        {
          msg: "Finished backfill. Waiting for the other chains.",
          params: dict{"chainId": JSON.Number(1.), "block": JSON.Number(100.)},
        },
        {
          msg: "Finished backfill.",
          params: dict{"chainId": JSON.Number(137.), "block": JSON.Number(100.)},
        },
      ])
    },
  )

  headScenario->Scenario.it(
    "Says neither is waiting when they finish together",
    ~sources=[{chain: 1, autoHeight: 100}, {chain: 137, autoHeight: 100}],
    ~captureLogs=true,
    async (~t, ~indexer, ~source) => {
      source(1).resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      source(137).resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.waitUntilReady()

      t.expect(indexer.logs()->finishLines).toStrictEqual([
        {
          msg: "Finished backfill.",
          params: dict{"chainId": JSON.Number(1.), "block": JSON.Number(100.)},
        },
        {
          msg: "Finished backfill.",
          params: dict{"chainId": JSON.Number(137.), "block": JSON.Number(100.)},
        },
      ])
    },
  )
})

// A run split one chain per worker: no chain in the process has a sibling, so
// what it waits on is the other processes, which is what the hold stands for.
describe("A supervised worker driving one chain", () => {
  let singleChainHeadScenario = Scenario.make(
    ~configYaml=`
name: finalize-backfill-logging-single-chain-head
rollback_on_reorg: false
disable_default_cross_chain: true
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:${chainYaml(1, "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3")}`,
    ~schema,
  )

  // Rollback off, so nothing keeps the chain below the head while it is held.
  singleChainHeadScenario->Scenario.it(
    "Says it is waiting when it reaches the head while the run holds it back",
    ~sources=[{chain: 1, autoHeight: 100}],
    ~holdRealtime=true,
    ~captureLogs=true,
    async (~t, ~indexer, ~source) => {
      source(1).resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.waitUntilIdle()
      indexer.releaseRealtime()
      await indexer.waitUntilReady()

      t.expect(indexer.logs()->reportedFinishAndPause).toStrictEqual([
        "Finished backfill. Waiting for the other chains.",
        indexesMessage,
      ])
    },
  )

  // Rollback on: held, the chain can only reach the safe block, and finishes
  // only after the release — when no other process is waited on any more.
  singleChainScenario->Scenario.it(
    "Says nothing about waiting when it finishes after the release",
    ~sources=[{chain: 1}],
    ~holdRealtime=true,
    ~captureLogs=true,
    async (~t, ~indexer, ~source) => {
      source(1).resolveGetHeightOrThrow(300)
      source(1).resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.waitUntilIdle()
      indexer.releaseRealtime()
      await indexer.waitUntilIdle()
      source(1).resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await indexer.waitUntilReady()

      t.expect(indexer.logs()->reportedFinishAndPause).toStrictEqual([
        "Finished backfill.",
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

      t.expect(indexer.logs()->Array.filter(({msg}) => msg === indexesMessage)).toStrictEqual([
        {msg: indexesMessage, params: dict{"chainId": JSON.Number(1.)}},
      ])
    },
  )
})
