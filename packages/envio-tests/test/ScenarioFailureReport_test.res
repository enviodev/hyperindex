open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: scenario-failure-report
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
        address: "0x0000000000000000000000000000000000000001"
`,
)

type rejection = {name: Nullable.t<string>, message: Nullable.t<string>}

// Read straight off the rejected value: a ReScript catch would wrap it again.
let rejectionOf: promise<unit> => promise<option<rejection>> = %raw(`promise =>
  promise.then(() => undefined, error => ({name: error?.name, message: error?.message}))`)

// A failure ends with where its run's logs were written; the path differs per
// run, so the report before it is what the exact cases compare.
let stripLogsLink = (rejection: option<rejection>) =>
  rejection->Option.map(rejection => rejection.message->Nullable.map(IndexerRunner.stripLogsLink))

let logsLinkOf = (rejection: option<rejection>) =>
  rejection
  ->Option.flatMap(rejection => rejection.message->Nullable.toOption)
  ->Option.flatMap(message =>
    switch message->String.lastIndexOf(IndexerRunner.logsLinkPrefix) {
    | -1 => None
    | index =>
      Some(message->String.slice(~start=index + IndexerRunner.logsLinkPrefix->String.length))
    }
  )

@module("node:fs") external readFileSync: (string, string) => string = "readFileSync"

describe("A failing scenario body", () => {
  // Wrapped in a ReScript exception, an assertion reached vitest as a plain
  // object: no diff, and the actual value collapsed to [Object].
  Async.it("fails with the assertion itself, so vitest can diff it", async t => {
    let rejection = await rejectionOf(
      scenario->Scenario.run(
        ~sources=[{chain: 1}],
        async (~indexer as _, ~source) => {
          let mock = source(1)
          mock.resolveGetHeightOrThrow(300)
          await mock.expectItemsQueries([{reply: LeavePending}])
          t.expect(1).toBe(2)
        },
      ),
    )
    t.expect(rejection->Option.map(rejection => rejection.name)).toEqual(
      Some(Nullable.make("AssertionError")),
    )
  })

  Async.it("says what each mock source had pending", async t => {
    let rejection = await rejectionOf(
      scenario->Scenario.run(
        ~sources=[{chain: 1}],
        // Pins the report a real-time run gives; the virtual one is pinned below.
        ~virtualTime=false,
        async (~indexer as _, ~source) => {
          let mock = source(1)
          mock.resolveGetHeightOrThrow(300)
          await mock.expectItemsQueries([{reply: LeavePending}])
          JsError.throwWithMessage("the body failed")
        },
      ),
    )
    t.expect(rejection->stripLogsLink).toEqual(
      Some(
        Nullable.make(`the body failed

Mock source for chain 1 at the failure:
  pending item queries:
    {partitionId: "0", fromBlock: 1, toBlock: Bounded(100), retryCount: 0}
  pending block-hash lookups: none
  height calls taken: 1`),
      ),
    )
  })

  Async.it("says what each mock source had pending after a ReScript exception", async t => {
    let rejection = await rejectionOf(
      scenario->Scenario.run(
        ~sources=[{chain: 1}],
        // Pins the report a real-time run gives; the virtual one is pinned below.
        ~virtualTime=false,
        async (~indexer as _, ~source) => {
          let mock = source(1)
          mock.resolveGetHeightOrThrow(300)
          await mock.expectItemsQueries([{reply: LeavePending}])
          throw(Not_found)
        },
      ),
    )
    t.expect(rejection->stripLogsLink).toEqual(
      Some(
        Nullable.make(`Not_found

Mock source for chain 1 at the failure:
  pending item queries:
    {partitionId: "0", fromBlock: 1, toBlock: Bounded(100), retryCount: 0}
  pending block-hash lookups: none
  height calls taken: 1`),
      ),
    )
  })

  // Logs stay out of the test output, which a passing run never needs; a
  // failure points at a file holding every line the run logged.
  Async.it("links the run's logs instead of printing them", async t => {
    let rejection = await rejectionOf(
      scenario->Scenario.run(
        ~sources=[{chain: 1}],
        async (~indexer as _, ~source) => {
          let mock = source(1)
          mock.resolveGetHeightOrThrow(300)
          await mock.expectItemsQueries([{reply: LeavePending}])
          JsError.throwWithMessage("the body failed")
        },
      ),
    )
    let ready =
      rejection
      ->logsLinkOf
      ->Option.map(
        path =>
          readFileSync(path, "utf8")
          ->String.trim
          ->String.split("\n")
          ->Array.map(line => JSON.parseOrThrow(line))
          ->Array.find(
            line =>
              line->JSON.Decode.object->Option.flatMap(line => line->Dict.get("msg")) ==
                Some(JSON.String("The indexer storage is ready. Starting indexing!")),
          ),
      )
    t.expect(ready).toEqual(
      Some(
        Some(
          JSON.parseOrThrow(`{"level":"info","msg":"The indexer storage is ready. Starting indexing!"}`),
        ),
      ),
    )
  })

  // On virtual time nothing the indexer schedules runs until the test advances
  // it, so a test that forgot to is told which timer it is waiting for, and a
  // poll it never accounted for is named with the steps around it.
  Async.it("on virtual time, says what the clock was holding and what ran", async t => {
    let rejection = await rejectionOf(
      scenario->Scenario.run(
        ~sources=[{chain: 1}],
        ~seed=1,
        async (~indexer as _, ~source) => {
          let mock = source(1)
          mock.resolveGetHeightOrThrow(300)
          await mock.expectNewHeightCalls(1)
          await mock.respondEmptyUpTo(300)
        },
      ),
    )
    t.expect(rejection->stripLogsLink).toEqual(
      Some(
        Nullable.make(`Height calls no expectation accounted for on source for chain 1: 1 (calls 2 to 2). Name each poll where the test causes it with \`expectNewHeightCalls(n)\`, so one nobody planned for fails at the step that caused it.

Mock source for chain 1 at the failure:
  pending item queries: none
  pending block-hash lookups: none
  height calls taken: 2

Virtual time at the failure: t=0ms, seed 1 (ENVIO_TEST_SEED=1 replays it)
  pending timers:
    height poll timeout due t=60000ms (in 60000ms), armed t=0ms
    stall poke due t=60164ms (in 60164ms), armed t=0ms
    stall timeout due t=120000ms (in 120000ms), armed t=0ms
  timeline:
    t=0ms source(1): height call 1 (pending)
    t=0ms armed height poll timeout for t=60000ms
    t=0ms armed stall poke for t=48812ms
    t=0ms armed stall timeout for t=60000ms
    t=0ms source(1): test answered heights with 300
    t=0ms cleared height poll timeout
    t=0ms cleared stall poke
    t=0ms cleared stall timeout
    t=0ms source(1): items query 1..100 (partition 0)
    t=0ms source(1): height call 2 (pending)
    t=0ms armed height poll timeout for t=60000ms
    t=0ms armed stall poke for t=60164ms
    t=0ms armed stall timeout for t=120000ms
    t=0ms source(1): items query 101.. (partition 0)
  Nothing the indexer schedules runs until the test advances time: \`await indexer.advanceTime(60000)\` fires the next timer (height poll timeout).`),
      ),
    )
  })
})

describe("A passing scenario body", () => {
  Async.it("reads every line the run logged as JSON", async t => {
    await scenario->Scenario.run(
      ~sources=[{chain: 1}],
      async (~indexer, ~source) => {
        let mock = source(1)
        mock.resolveGetHeightOrThrow(300)
        await mock.expectItemsQueries([{reply: LeavePending}])
        t.expect(
          indexer.allLogsAsJson()->Array.find(
            line => line->Dict.get("msg") == Some(JSON.String("Started querying")),
          ),
        ).toEqual(
          Some(
            dict{
              "level": JSON.String("trace"),
              "msg": JSON.String("Started querying"),
              "chainId": JSON.Number(1.),
              "partitions": JSON.parseOrThrow(`{"0":{"fromBlock":1,"targetBlock":100,"targetEvents":10000}}`),
            },
          ),
        )
      },
    )
  })
})
