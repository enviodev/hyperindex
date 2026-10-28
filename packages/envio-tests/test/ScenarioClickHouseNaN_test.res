open Vitest

// NaN and Infinity are refused whichever column shape carries them, and the
// refusal reads the same either way. A float list would otherwise be refused
// for the `null` `JSON.stringify` renders it as, and a scalar Float64 column
// would take the raw bytes and store a value no reader can render — so what an
// operator is shown has to name the value the handler actually wrote.

let scenario = (~readings) =>
  Scenario.make(
    ~configYaml=`
name: clickhouse-nan
storage:
  postgres:
    default: true
  clickhouse: true
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
`,
    ~schema=`
type Plain {
  id: ID!
  value: String!
}

type Readings @storage(clickhouse: {}) {
  id: ID!
  samples: [Float!]!
  latest: Float!
}
`,
    ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ context }) => {
  context.Readings.set(${readings});
});
`,
    ~unsupported=Scenario.configuresOwnStorage,
  )

let storedReadings = async () => {
  let database = TestClickHouse.currentDatabase()
  let stored = await TestClickHouse.query(
    `SELECT count() FROM \`${database}\`.\`Readings\` FORMAT TabSeparated`,
  )
  stored->String.trim
}

let refusesWith = (~name, ~case, ~readings, ~reason) =>
  describe(name, () => {
    let refusal = Scenario.captureRefusal()
    scenario(~readings)->Scenario.it(case, ~sources=[{chain: 1}], ~onError=refusal.onError, async (
      ~t,
      ~indexer as _,
      ~source,
    ) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(10)

      await source.expectItemsQueries([
        {
          fromBlock: 0,
          toBlock: Unbounded,
          reply: Respond({
            items: [{event: "Token.Transfer", blockNumber: 5, logIndex: 0}],
            latestFetchedBlockNumber: 10,
          }),
        },
      ])

      let failure = await refusal.awaitRefusalReason()

      t.expect((failure, await storedReadings())).toEqual((Some(reason), "0"))
    })
  })

refusesWith(
  ~name="ClickHouse refuses a float that has no JSON form",
  ~case="names NaN rather than the null it serializes to",
  ~readings=`{ id: "nan", samples: [1.5, NaN], latest: 2.0 }`,
  ~reason="NaN is not a finite number, so it cannot be stored in the `samples` column. Store a finite number, or keep it out of the entity.",
)

refusesWith(
  ~name="ClickHouse refuses a non-finite float in a scalar column",
  ~case="names Infinity the same way it names a value in a list",
  ~readings=`{ id: "nan", samples: [1.5], latest: Infinity }`,
  ~reason="Infinity is not a finite number, so it cannot be stored in the `latest` column. Store a finite number, or keep it out of the entity.",
)
