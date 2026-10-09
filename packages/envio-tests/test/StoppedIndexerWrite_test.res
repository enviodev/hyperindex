open Vitest

let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: stopped-indexer-write
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Gravatar {
  id: ID!
  owner: String!
}
`,
)

// Holds the index build open until released, and counts the chain metadata
// writes that reach storage once the indexer has stopped.
let makeHeldStorage = () => {
  let finalizeStarted = ref(None)
  let releaseFinalize = ref(None)
  let isStopped = ref(false)
  let writesAfterStop = ref(0)
  let started = Promise.make((resolve, _) => finalizeStarted := Some(resolve))
  let released = Promise.make((resolve, _) => releaseFinalize := Some(resolve))
  let mapStorage = (storage: Persistence.storage) => {
    ...storage,
    finalizeBackfill: async (~entities, ~chainIds, ~readyAt) => {
      finalizeStarted.contents->Option.forEach(resolve => resolve())
      await released
      await storage.finalizeBackfill(~entities, ~chainIds, ~readyAt)
    },
    setChainMeta: chainsData => {
      if isStopped.contents {
        writesAfterStop := writesAfterStop.contents + 1
      }
      storage.setChainMeta(chainsData)
    },
  }
  let release = () => releaseFinalize.contents->Option.forEach(resolve => resolve())
  (started, release, isStopped, writesAfterStop, mapStorage)
}

describe("Stopping an indexer while it finalizes the backfill", () => {
  let (finalizeStarted, releaseFinalize, isStopped, writesAfterStop, mapStorage) = makeHeldStorage()
  let errors = []

  // A stopped indexer's schema is dropped straight after, so a write landing
  // later fails, and the default onError exits the test worker.
  scenario->Scenario.it(
    "Writes nothing once stopped",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~mapStorage,
    ~onError=err => errors->Array.push(err)->ignore,
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      source.resolveGetHeightOrThrow(100)
      source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100, ~knownHeight=100)
      await finalizeStarted

      let stopped = indexer.stop()
      releaseFinalize()
      await stopped
      isStopped := true
      await Utils.delay(Env.ThrottleWrites.chainMetadataIntervalMillis + 200)

      t.expect((writesAfterStop.contents, errors->Array.length)).toEqual((0, 0))
    },
  )
})
