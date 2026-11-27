open Vitest

// https://github.com/enviodev/hyperindex/issues/662
// An operator looking at pg_stat_activity, or at a pooler's or provider's
// connection list, has to be able to tell the indexer's connections apart from
// everything else on the database, and which release opened them.

let scenario = Scenario.make(
  ~configYaml=`
name: pg-application-name
chains:
  - id: 1337
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
type Note {
  id: ID!
}
`,
  ~unsupported=[{backend: #clickhouse, reason: "names a Postgres connection"}],
)

describe("A Postgres connection the indexer opens", () => {
  scenario->Scenario.it(
    "is named after hyperindex and its version",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source as _) => {
      await indexer.usePostgresSql(
        async sql => {
          let named: array<{
            "name": string,
          }> = await sql->Sql.queryForTests(`SELECT application_name AS "name" FROM pg_stat_activity WHERE pid = pg_backend_pid();`)

          t.expect(named->Array.map(row => row["name"])).toEqual([
            `hyperindex/${Utils.EnvioPackage.value.version}`,
          ])
        },
      )
    },
  )
})
