open Vitest

// The stored config lives in Postgres and decides whether a resume is allowed
// at all. An entity added since the ClickHouse tables were built has no history
// table there, so the resume is refused off the stored config first: the user
// reads which config paths changed rather than a ClickHouse error about a
// table it doesn't have.

let configYaml = `
name: clickhouse-resume-refusal
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`

let unsupported: array<Scenario.unsupported> = [
  {backend: #postgres, reason: "asserts against a ClickHouse server"},
]

let scenario = Scenario.make(
  ~configYaml,
  ~unsupported,
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
)

let withExtraEntity = Scenario.make(
  ~configYaml,
  ~unsupported,
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}

type Extra {
  id: ID!
}
`,
)

describe("Restarting ClickHouse storage with an added entity", () => {
  scenario->Scenario.it(
    "is refused off the stored config, before ClickHouse is asked",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source as _) => {
      let message = switch await indexer.restart(~config=withExtraEntity.config, ()) {
      | _ => "the restart to fail, but it succeeded"
      | exception JsExn(error) => error->JsExn.message->Option.getOr("an error without a message")
      | exception Persistence.StorageError({message}) => message
      }

      t.expect(
        message,
      ).toBe(`The following config changes are incompatible with the existing indexer data:

    - entities[1]

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_CLICKHOUSE_DATABASE=<new_db> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`)
    },
  )
})
