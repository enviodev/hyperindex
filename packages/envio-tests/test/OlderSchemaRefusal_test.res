open Vitest

// A schema whose addresses are keyed without the contract mapping was written
// by an older envio. Restarting onto it has to refuse with the error that says
// so, not fail on a missing table halfway through the resume.

let scenario = Scenario.make(
  ~configYaml=`
name: older-schema-refusal
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
      - name: NftFactory
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Tally {
  id: ID!
  wide: BigInt! @config(precision: 76)
}
`,
)

let alterPostgres = (indexer: IndexerRunner.t, alter) =>
  indexer.usePostgresSql(async sql => {
    let _ = await sql->Sql.queryForTests(alter(indexer.pgSchema))
  })

let expectOlderVersionRefusal = async (
  ~t: Vitest.testContext,
  ~indexer: IndexerRunner.t,
  alter: unit => promise<unit>,
) => {
  await alter()

  let message = switch await indexer.restart() {
  | _ => "the restart to fail, but it succeeded"
  | exception JsExn(error) => error->JsExn.message->Option.getOr("")
  }

  t.expect(
    message->String.includes("storage was initialized by an older envio version"),
    ~message,
  ).toBe(true)
}

describe("Restarting onto a schema an older envio wrote", () => {
  scenario->Scenario.it(
    "refuses, naming the older envio version",
    ~unsupported=[
      {
        backend: #clickhouse,
        reason: "drops envio_contracts with Postgres SQL, which a run keeping no entity in Postgres skips",
      },
    ],
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source as _) =>
      await expectOlderVersionRefusal(
        ~t,
        ~indexer,
        () => indexer->alterPostgres(pgSchema => `DROP TABLE "${pgSchema}"."envio_contracts";`),
      ),
  )

  // An older envio kept no instance to pair its Postgres with the ClickHouse
  // beside it, which says nothing about either being another deployment's.
  scenario->Scenario.it(
    "refuses one with no instance pairing it with ClickHouse, naming the older envio version",
    ~unsupported=[
      {backend: #postgres, reason: "pairs Postgres with a ClickHouse beside it"},
      {
        backend: #clickhouse,
        reason: "drops envio_info's instance with Postgres SQL, which a run keeping no entity in Postgres skips",
      },
    ],
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source as _) =>
      await expectOlderVersionRefusal(
        ~t,
        ~indexer,
        () =>
          indexer->alterPostgres(
            pgSchema => `ALTER TABLE "${pgSchema}"."envio_info" DROP COLUMN "instance";`,
          ),
      ),
  )

  // https://github.com/enviodev/hyperindex/issues/1816
  // An older envio kept a number bounded past 38 digits as a String, and the
  // 32 bytes of a Decimal written to that column would misalign every row
  // after it.
  scenario->Scenario.it(
    "refuses a number bounded past 38 digits kept as a String, naming the older envio version",
    ~unsupported=[{backend: #postgres, reason: "the column is ClickHouse's"}],
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source as _) =>
      await expectOlderVersionRefusal(
        ~t,
        ~indexer,
        async () => {
          let _ = await TestClickHouse.query(
            `ALTER TABLE \`${TestClickHouse.currentDatabase()}\`.\`envio_history_Tally\` MODIFY COLUMN \`wide\` String`,
          )
        },
      ),
  )
})
