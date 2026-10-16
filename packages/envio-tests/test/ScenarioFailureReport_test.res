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
    t.expect(rejection->Option.map(rejection => rejection.message)).toEqual(
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
    t.expect(rejection->Option.map(rejection => rejection.message)).toEqual(
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
})
