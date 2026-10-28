open Vitest

// `start_block: latest` must resolve once, against the chain's head at first
// deploy, and then never again - `indexer.restart()` (a normal resume, not
// the CLI's `-r`/`--restart` reset flag) reuses the persisted value even if
// the chain's head has moved on, so any downtime gets backfilled rather than
// skipped.
//
// The resolution happens while the chain is being built, from the very sources
// it then indexes with. `IndexerRunner` fully awaits that before a test body
// ever runs - so, unlike every other height call in this suite, it can't be
// answered via `source.setAutoHeight` from inside the test. It's pre-configured
// via `~autoHeight` on the mock instead (see MockSource.make /
// Scenario.sourceMock).

let schema = `
type A {
  id: ID!
}
`

let contractsYaml = `
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
`

let gravatar = "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"

let chainYaml = (~chainId, ~startBlock) =>
  `
  - id: ${chainId->Int.toString}
    rpc:
      url: https://rpc${chainId->Int.toString}.example.test
      for: sync
    start_block: ${startBlock}
    contracts:
      - name: Gravatar
        address: "${gravatar}"
`

let scenario = Scenario.make(
  ~configYaml=`
name: start-block-latest${contractsYaml}chains:${chainYaml(~chainId=1337, ~startBlock="latest")}`,
  ~schema,
  ~virtualTime=true,
)

let mixedScenario = Scenario.make(
  ~configYaml=`
name: start-block-latest-mixed${contractsYaml}chains:${chainYaml(
      ~chainId=1,
      ~startBlock="5",
    )}${chainYaml(~chainId=1337, ~startBlock="latest")}`,
  ~schema,
  ~virtualTime=true,
)

// A `where` predicate runs while handlers register. On a first `latest` deploy
// that has to be the resolved head - a predicate computing a range from it
// (`_gte: chain.startBlock + n`) is silently wrong otherwise.
let registrationScenario = Scenario.make(
  ~configYaml=`
name: start-block-latest-registration${contractsYaml}chains:${chainYaml(
      ~chainId=1337,
      ~startBlock="latest",
    )}`,
  ~schema=`
type Seen {
  id: ID!
  seenStartBlock: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

let seenAtRegistration = -1;

indexer.onBlock({
  name: "blocks",
  where: ({ chain }) => {
    if (chain.id === 1337) { seenAtRegistration = chain.startBlock; }
    return chain.id === 1337;
  },
}, async ({ context }) => {
  context.Seen.set({ id: "only", seenStartBlock: seenAtRegistration });
});
`,
  ~virtualTime=true,
)

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

let persistedStartBlocks = async (~sql, ~pgSchema) => {
  let rows: array<{
    "id": int,
    "start_block": int,
  }> = await sql->Sql.queryForTests(
    `SELECT "id", "start_block" FROM "${pgSchema}"."envio_chains" ORDER BY "id";`,
  )
  rows->Array.map(row => (row["id"], row["start_block"]))
}

describe("start_block: latest", () => {
  scenario->Scenario.it(
    "resolves latest to the chain's head on first deploy, and never re-resolves on restart",
    ~sources=[{chain: 1337, methods, autoHeight: 1000}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      let {sql, pgSchema} = indexer.pg

      await source.expectItemsQueries([
        {fromBlock: 1000, reply: Respond({items: [], latestFetchedBlockNumber: 1000})},
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        await persistedStartBlocks(~sql, ~pgSchema),
        ~message="latest resolves to the head observed at first deploy",
      ).toEqual([(1337, 1000)])

      // The resolver's probe and the chain's own startup call.
      await source.expectNewHeightCallsAtLeast(2)

      // The head moves on while the indexer is "down" - restart must not
      // re-resolve "latest" against it.
      source.setAutoHeight(5000)
      let restarted = await indexer.restart()
      await restarted.waitUntilReady()
      // The chain's own startup call, and no probe to re-resolve `latest`.
      await source.expectNewHeightCalls(1)

      t.expect(
        await persistedStartBlocks(~sql, ~pgSchema),
        ~message="start_block is reused from the first deploy, not re-resolved to the new head",
      ).toEqual([(1337, 1000)])
    },
  )

  registrationScenario->Scenario.it(
    "is the resolved head by the time handlers register",
    ~sources=[{chain: 1337, methods, autoHeight: 1000}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await source.expectItemsQueries([
        {fromBlock: 1000, reply: Respond({items: [], latestFetchedBlockNumber: 1000})},
      ])
      await indexer.getBatchWritePromise()

      let {sql, pgSchema} = indexer.pg
      let rows: array<{
        "seenStartBlock": int,
      }> = await sql->Sql.queryForTests(`SELECT "seenStartBlock" FROM "${pgSchema}"."Seen";`)

      t.expect(rows->Array.map(row => row["seenStartBlock"])).toEqual([1000])
    },
  )

  mixedScenario->Scenario.it(
    "only resolves latest for the chain configured with it",
    ~sources=[{chain: 1, methods, autoHeight: 10}, {chain: 1337, methods, autoHeight: 2000}],
    async (~t, ~indexer, ~source) => {
      let source1 = source(1)
      let source1337 = source(1337)
      let {sql, pgSchema} = indexer.pg

      await source1.expectItemsQueries([
        {fromBlock: 5, reply: Respond({items: [], latestFetchedBlockNumber: 10})},
      ])
      await source1337.expectItemsQueries([
        {fromBlock: 2000, reply: Respond({items: [], latestFetchedBlockNumber: 2000})},
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        await persistedStartBlocks(~sql, ~pgSchema),
        ~message="chain 1 keeps its configured start block; only chain 1337 resolves latest",
      ).toEqual([(1, 5), (1337, 2000)])
    },
  )

  scenario->Scenario.it(
    "never subscribes to a height stream while resolving",
    ~sources=[{chain: 1337, methods: [...methods, #createHeightSubscription], autoHeight: 500}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      let {sql, pgSchema} = indexer.pg
      // Reading a start block is one question with one answer. A stream is for
      // a height that keeps moving, which is the indexer loop's business.
      t.expect((
        await persistedStartBlocks(~sql, ~pgSchema),
        source.heightSubscriptionCalls->Array.length,
      )).toEqual(([(1337, 500)], 0))
    },
  )
})

// What startup refused with, without the line that says where its logs went.
let startupFailure = async (scenario, ~sources, ~startBlockRetry=?, ~sourceTiming=?) =>
  switch await scenario->Scenario.run(~sources, ~startBlockRetry?, ~sourceTiming?, async (
    ~indexer as _,
    ~source as _,
  ) => ()) {
  | () => None
  | exception JsExn(exn) =>
    exn->JsExn.message->Option.map(msg => msg->String.split("\n\nLogs:")->Array.getUnsafe(0))
  }

let resolvedStartBlocks = async (scenario, ~sources, ~startBlockRetry=?, ~sourceTiming=?) => {
  let resolved = ref([])
  await scenario->Scenario.run(~sources, ~startBlockRetry?, ~sourceTiming?, async (
    ~indexer,
    ~source as _,
  ) => {
    let {sql, pgSchema} = indexer.pg
    resolved := (await persistedStartBlocks(~sql, ~pgSchema))
  })
  resolved.contents
}

describe("start_block: latest against sources that struggle", () => {
  Async.it("keeps asking a failing source until it answers", async t => {
    t.expect(
      await scenario->resolvedStartBlocks(
        ~sources=[
          {
            chain: 1337,
            methods,
            startupHeights: [
              HeightFailure("temporary network blip"),
              HeightFailure("another blip"),
              Height(777),
            ],
          },
        ],
        ~sourceTiming={getHeightRetryInterval: (~retry as _) => 1},
      ),
    ).toEqual([(1337, 777)])
  })

  Async.it("fails over to a fallback source when the primary stays quiet", async t => {
    t.expect(
      await scenario->resolvedStartBlocks(
        ~sources=[
          {chain: 1337, methods},
          {chain: 1337, methods, sourceFor: Fallback, autoHeight: 999},
        ],
        // The window the primary gets to itself before a fallback is recruited.
        ~sourceTiming={newBlockStallTimeout: 1},
      ),
    ).toEqual([(1337, 999)])
  })

  Async.it("with a single attempt, takes the first source that answers", async t => {
    t.expect(
      await scenario->resolvedStartBlocks(
        ~sources=[
          {chain: 1337, methods, startupHeights: [HeightFailure("primary is down")]},
          {chain: 1337, methods, sourceFor: Fallback, autoHeight: 4242},
        ],
        ~startBlockRetry=Once,
      ),
    ).toEqual([(1337, 4242)])
  })

  Async.it("with a single attempt, gives up after one per source and says why", async t => {
    t.expect(
      await scenario->startupFailure(
        ~sources=[
          {chain: 1337, methods, startupHeights: [HeightFailure("primary is down")]},
          {
            chain: 1337,
            methods,
            sourceFor: Fallback,
            startupHeights: [HeightFailure("fallback is down too")],
          },
        ],
        ~startBlockRetry=Once,
      ),
    ).toEqual(
      Some(`Chain 1337: couldn't resolve the "latest" start block - no source answered a height request.
  MockSource: primary is down
  MockSource: fallback is down too`),
    )
  })

  Async.it("says what's wrong when no source can serve historical sync", async t => {
    // Nothing left to ask is a config error rather than an unanswered request,
    // and reads as the same config error the chain itself would raise.
    t.expect(
      await scenario->startupFailure(
        ~sources=[{chain: 1337, methods, sourceFor: Realtime, autoHeight: 100}],
        ~startBlockRetry=Once,
      ),
    ).toEqual(Some("Invalid configuration, no data-source for historical sync provided"))
  })
})

describe("start_block: latest validation", () => {
  let pastEndBlock = Scenario.make(
    ~configYaml=`
name: start-block-latest-end-block${contractsYaml}chains:${chainYaml(
        ~chainId=1337,
        ~startBlock="latest",
      )}    end_block: 50
`,
    ~schema,
  )

  Async.it("refuses a latest that resolves past end_block", async t => {
    t.expect(
      await pastEndBlock->startupFailure(~sources=[{chain: 1337, methods, autoHeight: 100}]),
    ).toEqual(
      Some(`Chain 1337: the "latest" start block resolved to 100, which is past the configured end_block (50). There is nothing to index - remove end_block, raise it above the chain's current head, or pin start_block to a fixed value instead of "latest".`),
    )
  })
})

// `start_block: latest` is offered on every ecosystem, and each one builds its
// own address store and sources on the way to a height request.
describe("start_block: latest on every ecosystem", () => {
  [
    (
      "Fuel",
      `
name: fuel-latest
ecosystem: fuel
chains:
  - id: 0
    start_block: latest
`,
      `
import { indexer } from "envio";
indexer.onBlock({ name: "blocks" }, async () => {});
`,
    ),
    (
      "SVM",
      `
name: svm-latest
ecosystem: svm
chains:
  - id: solana
    start_slot: latest
    rpc: https://api.mainnet-beta.solana.com
`,
      `
import { indexer } from "envio";
indexer.onSlot({ name: "slots" }, async () => {});
`,
    ),
  ]->Array.forEach(((ecosystem, configYaml, handlers)) => {
    // A block handler gives the chain something to fetch once it starts.
    let scenario = Scenario.make(~configYaml, ~schema, ~handlers)
    let chain = scenario.config.chainMap->ChainMap.keys->Utils.Array.firstUnsafe->ChainId.toInt

    Async.it(
      `resolves latest on ${ecosystem}`,
      async t => {
        t.expect(
          await scenario->resolvedStartBlocks(~sources=[{chain, methods, autoHeight: 8888}]),
        ).toEqual([(chain, 8888)])
      },
    )
  })
})
