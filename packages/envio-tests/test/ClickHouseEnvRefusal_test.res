open Vitest

// `storage.clickhouse` on with nowhere to reach ClickHouse: the start refuses,
// naming every variable it is missing at once.

let scenario = Scenario.make(
  ~configYaml=`
name: clickhouse-env-refusal
storage:
  postgres:
    default: true
  clickhouse:
    default: true
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

describe("Starting with ClickHouse storage but no ClickHouse settings", () => {
  let name = "refuses, naming every missing variable"
  switch IndexerRunner.selectedBackend {
  // That leg sets the variables for every run.
  | #clickhouse => Async.it_skip(`${name} [no clickhouse: the leg provides them]`, async _ => ())
  | #postgres =>
    Async.it(name, async t => {
      let env = NodeJs.Process.process.env
      let saved = names->Array.map(name => (name, env->Dict.get(name)))
      names->Array.forEach(name => env->Dict.delete(name))
      let message = switch await scenario->Scenario.run(
        ~sources=[{chain: 1}],
        async (~indexer as _, ~source as _) => (),
      ) {
      | () => "the start to fail, but it succeeded"
      | exception JsExn(error) => error->JsExn.message->Option.getOr("")
      }
      saved->Array.forEach(
        ((name, value)) =>
          switch value {
          | Some(value) => env->Dict.set(name, value)
          | None => ()
          },
      )

      t.expect(message).toBe(
        "ClickHouse storage is enabled but required env vars are not set: ENVIO_CLICKHOUSE_HOST, ENVIO_CLICKHOUSE_USERNAME, ENVIO_CLICKHOUSE_PASSWORD, ENVIO_CLICKHOUSE_DATABASE. Please set them, disable clickhouse in the `storage` config, or run `envio dev` for a pre-configured local ClickHouse.",
      )
    })
  }
})
