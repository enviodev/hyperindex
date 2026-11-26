open Vitest

// What `advanceTime` waits for before it fires a timer: everything the indexer
// is doing that the timer could otherwise land in the middle of.
let scenario = Scenario.make(
  ~configYaml=`
name: advance-time-settle
rollback_on_reorg: false
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
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

// Every storage call answers this much later than it would, the way a loaded
// runner's ClickHouse does.
let slowStorage: Persistence.storage => Persistence.storage = %raw(`storage =>
  new Proxy(storage, {
    get: (target, key) => {
      const value = target[key];
      return typeof value === "function"
        ? (...args) => new Promise(resolve => setTimeout(resolve, 25)).then(() => value.apply(target, args))
        : value;
    },
  })`)

describe("advanceTime", () => {
  // https://github.com/enviodev/hyperindex/actions/runs/41418919751/job/125191181354
  scenario->Scenario.it(
    "Waits out the storage the indexer is waiting on before firing a timer",
    ~sources=[{chain: 1337, pollingInterval: 1}],
    ~mapStorage=slowStorage,
    async (~t as _, ~indexer, ~source) => {
      let mock = source(1337)
      mock.resolveGetHeightOrThrow(100)
      await mock->RealtimeChain.answerQuery(~fromBlock=1, ~toBlock=100)
      await mock.expectNewHeightCalls(2)
      mock.setAutoHeight(100)
      // Catching up goes through storage before the chain switches to
      // realtime and polls every millisecond: its first poll, then two more.
      await indexer.advanceTime(2)
      await mock.expectNewHeightCalls(3)
    },
  )
})
