open Vitest

// The mock's answers are the test's only lever on the indexer's inputs. Three
// properties make them usable without counting event-loop ticks: an answer
// given before its query arrives is parked and claimed by that query; an answer
// that could land on several pending queries is refused rather than broadcast;
// a parked answer no query ever claimed fails the run.
let scenario = Scenario.make(
  ~configYaml=`
name: mock-answers
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Token
        address:
          - "0x0000000000000000000000000000000000000001"
          - "0x0000000000000000000000000000000000000002"
`,
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
)

let sources: array<Scenario.sourceMock> = [{chain: 1, methods: [#getHeightOrThrow, #getItemsOrThrow]}]

describe("MockSource answers", () => {
  scenario->Scenario.it(
    "claims an item answer given before the indexer asked for it",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)

      // The chain can't query for items until it knows the head, so there is
      // nothing pending to answer here.
      t.expect(mock.getItemsOrThrowCalls->Array.length, ~message="no item query yet").toBe(0)
      mock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      mock.resolveGetHeightOrThrow(300)
      await indexer.getBatchWritePromise()

      t.expect(
        (mock.unclaimedAnswers(), await indexer.metric("envio_progress_block")),
        ~message="the item query took the parked answer and carried the chain to the head",
      ).toEqual(([], [{value: "300", labels: Dict.fromArray([("chainId", "1")])}]))
    },
  )

  // Two addresses on one contract with `maxAddrInPartition=1` give the chain two
  // partitions, so two item queries are in flight at once.
  scenario->Scenario.it(
    "refuses an item answer that matches more than one pending query",
    ~sources,
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(300)
      await Scenario.waitUntil(
        () => mock.getItemsOrThrowCalls->Array.length === 2,
        ~message="both partitions query",
      )

      let ambiguous = try {
        mock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
        None
      } catch {
      | JsExn(exn) => exn->JsExn.message
      }
      t.expect(
        ambiguous,
        ~message="an unfiltered answer names the queries it could not choose between",
      ).toEqual(
        Some(
          "resolveGetItemsOrThrow matches 2 pending queries, so which one it answers is a guess:\n" ++
          "  {p: 0, fromBlock: 1, toBlock: 100}\n" ++
          "  {p: 1, fromBlock: 1, toBlock: 100}\n" ++
          "Narrow it with ~filter, or use drainItemsQueries to empty-response them all.",
        ),
      )

      mock.resolveGetItemsOrThrow(
        [],
        ~filter=call => call.payload["p"] === "1",
        ~latestFetchedBlockNumber=300,
      )
      t.expect(
        mock.getItemsOrThrowCalls->Array.map(call => call.payload["p"]),
        ~message="the filter answered exactly the partition it named",
      ).toEqual(["0"])

      mock.drainItemsQueries(~latestFetchedBlockNumber=300)
      await indexer.getBatchWritePromise()
    },
  )

  Async.it("fails the run when a parked answer is never claimed", async t => {
    let failure = try {
      await scenario->Scenario.run(~sources, async (~indexer, ~source) => {
        let mock = source(1)
        mock.resolveGetHeightOrThrow(300)
        // No query ever carries this partition id, so the answer sits parked.
        mock.resolveGetItemsOrThrow([], ~filter=call => call.payload["p"] === "nonexistent")
        await Scenario.waitUntil(
          () => mock.getItemsOrThrowCalls->Array.length > 0,
          ~message="the chain reaches its first item query",
        )
        mock.drainItemsQueries(~latestFetchedBlockNumber=300)
        await indexer.getBatchWritePromise()
      })
      None
    } catch {
    | JsExn(exn) => exn->JsExn.message
    }
    t.expect(
      failure->Option.map(message => message->String.includes("resolveGetItemsOrThrow at")),
      ~message="the unclaimed answer is reported with its call site",
    ).toEqual(Some(true))
  })
})
