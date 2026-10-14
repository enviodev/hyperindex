open Vitest

// `storage.clickhouse` on with nowhere to reach ClickHouse: the start refuses,
// naming every variable it is missing at once.

let scenario = (~storage) =>
  Scenario.make(
    ~configYaml=`
name: clickhouse-env-refusal
storage:${storage}
chains:
  - id: 1
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
type Tally {
  id: ID!
}
`,
  )

let names = [
  "ENVIO_CLICKHOUSE_HOST",
  "ENVIO_CLICKHOUSE_USERNAME",
  "ENVIO_CLICKHOUSE_PASSWORD",
  "ENVIO_CLICKHOUSE_DATABASE",
]

let refusal = async scenario => {
  // A developer's shell or an earlier run in the same worker may have set
  // them, and the refusal is only reachable with all four gone.
  let env = NodeJs.Process.process.env
  let saved = names->Array.map(name => (name, env->Dict.get(name)))
  names->Array.forEach(name => env->Dict.delete(name))
  let message = switch await scenario->Scenario.run(
    ~sources=[{chain: 1}],
    ~provideClickHouse=false,
    async (~indexer as _, ~source as _) => (),
  ) {
  | () => "the start to fail, but it succeeded"
  | exception JsExn(error) => error->JsExn.message->Option.getOr("")
  | exception error => `an unexpected failure: ${error->JSON.stringifyAny->Option.getOr("")}`
  }
  saved->Array.forEach(((name, value)) =>
    switch value {
    | Some(value) => env->Dict.set(name, value)
    | None => ()
    }
  )
  message
}

describe("Starting with ClickHouse storage but no ClickHouse settings", () => {
  Async.it("refuses, naming every missing variable", async t => {
    let message = await refusal(
      scenario(
        ~storage=`
  postgres:
    default: true
  clickhouse:
    default: true`,
      ),
    )
    t.expect(message).toBe(
      "ClickHouse storage is enabled but required env vars are not set: ENVIO_CLICKHOUSE_HOST, ENVIO_CLICKHOUSE_USERNAME, ENVIO_CLICKHOUSE_PASSWORD, ENVIO_CLICKHOUSE_DATABASE. Please set them, disable clickhouse in the `storage` config, or run `envio dev` for a pre-configured local ClickHouse.",
    )
  })

  Async.it("doesn't suggest disabling ClickHouse when it's the only store", async t => {
    let message = await refusal(
      scenario(
        ~storage=`
  postgres: false
  clickhouse: true`,
      ),
    )
    t.expect(message).toBe(
      "ClickHouse storage is enabled but required env vars are not set: ENVIO_CLICKHOUSE_HOST, ENVIO_CLICKHOUSE_USERNAME, ENVIO_CLICKHOUSE_PASSWORD, ENVIO_CLICKHOUSE_DATABASE. Please set them, or run `envio dev` for a pre-configured local ClickHouse.",
    )
  })
})
