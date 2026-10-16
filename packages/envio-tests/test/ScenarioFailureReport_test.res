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
let withoutLogsLink = (rejection: option<rejection>) =>
  rejection->Option.map(rejection => rejection.message->Nullable.map(IndexerRunner.withoutLogsLink))

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
        async (~indexer as _, ~source) => {
          let mock = source(1)
          mock.resolveGetHeightOrThrow(300)
          await mock.expectItemsQueries([{reply: LeavePending}])
          JsError.throwWithMessage("the body failed")
        },
      ),
    )
    t.expect(rejection->withoutLogsLink).toEqual(
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
        async (~indexer as _, ~source) => {
          let mock = source(1)
          mock.resolveGetHeightOrThrow(300)
          await mock.expectItemsQueries([{reply: LeavePending}])
          throw(Not_found)
        },
      ),
    )
    t.expect(rejection->withoutLogsLink).toEqual(
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
          indexer.jsonLogs()->Array.find(
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
