open Vitest

// A restart resumes the transaction handlers where the previous run stopped:
// the transactions already handled aren't handled again, and the ones the
// chain grew by while the indexer was down are.

let alice = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
let bob = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

let served = ServedEvmChain.serveDuringSuite(
  ~hyperSyncPort=18681,
  ~rpcPort=18682,
  ~height=6,
  ~logs=[],
  ~transactions=[1, 2, 3, 4, 5, 6]->Array.map(blockNumber => {
    ServedEvmChain.blockNumber,
    transactionIndex: 0,
    from: alice,
    to: bob,
  }),
)

let scenario = Scenario.make(
  ~configYaml=`
name: on-transaction-resume
chains:
  - id: 1
    start_block: 1
    end_block: 6
    hypersync_config:
      url: ${ServedEvmChain.url(served.hyperSyncPort)}
`,
  ~schema=`
type Seen {
  id: ID!
}

type Tally {
  id: ID!
  count: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onTransaction(
  { name: "from-alice", where: () => ({ transaction: { from: ["${alice}"] } }) },
  async ({ transaction, block, context }) => {
    context.Seen.set({ id: \`\${block.number}-\${transaction.transactionIndex}\` });
    const tally = (await context.Tally.get("runs")) ?? { id: "runs", count: 0 };
    context.Tally.set({ ...tally, count: tally.count + 1 });
  },
);
`,
)

type seenRow = {id: string}
type tallyRow = {id: string, count: int}

let readSeen = async (indexer: IndexerRunner.t) => {
  let rows: array<seenRow> = await indexer.query("Seen")
  rows->Array.map(row => row.id)->ServedEvmChain.sorted
}

let readTally = async (indexer: IndexerRunner.t) => {
  let rows: array<tallyRow> = await indexer.query("Tally")
  rows->Array.map(row => row.count)
}

let seenAtLeast = async (indexer, count) => {
  let deadline = Date.now() +. 10_000.
  while (await readSeen(indexer))->Array.length < count && Date.now() < deadline {
    await Utils.delay(50)
  }
  await readSeen(indexer)
}

describe("onTransaction across a restart", () => {
  Async.it("handles each transaction once, the later ones after the resume", async t => {
    let hyperSync = (served->ServedEvmChain.servers).hyperSync
    hyperSync->MockHyperSyncServer.setHeight(3)
    // The resumed run reaches the end block, which is an exit.
    let exited = ref(false)
    await scenario->Scenario.run(
      ~yamlSources=true,
      ~onExit=() => exited := true,
      async (~indexer, ~source as _) => {
        let before = await indexer->seenAtLeast(3)
        await indexer.stop()
        hyperSync->MockHyperSyncServer.setHeight(6)
        let resumed = await indexer.restart()
        await Scenario.waitUntil(
          () => exited.contents,
          ~message="the resumed run to reach its end block",
          ~timeoutMs=10000.,
        )
        t.expect((before, await readSeen(resumed), await readTally(resumed))).toEqual((
          ["1-0", "2-0", "3-0"],
          ["1-0", "2-0", "3-0", "4-0", "5-0", "6-0"],
          [6],
        ))
      },
    )
  })
})
