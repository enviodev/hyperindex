open Vitest

// `envio start --chain` resumes only the chains it drives. The ClickHouse trim
// on resume drops what lies past the resumed checkpoint, and a sibling process
// is writing past its own checkpoint the whole time: trimming its chain would
// delete rows it has already committed and will never send again.

let scenario = Scenario.make(
  ~configYaml=`
name: clickhouse-isolated-resume
disable_default_cross_chain: true
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    rpc:
      url: https://rpc1.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
  - id: 137
    rpc:
      url: https://rpc137.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000002"
`,
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
  ~unsupported=[{backend: #postgres, reason: "asserts against a ClickHouse server"}],
)

let orphanCheckpointId = "999999999"

describe("ClickHouse sink resumed by one chain's process", () => {
  scenario->Scenario.it(
    "trims past its own chain's checkpoint and leaves the other chain's rows alone",
    ~sources=[{chain: 1}, {chain: 137}],
    async (~t, ~indexer, ~source as _) => {
      let database = TestClickHouse.currentDatabase()

      let _ = await TestClickHouse.query(
        `INSERT INTO \`${database}\`.\`envio_checkpoints\` (\`id\`, \`chain_id\`, \`block_number\`, \`block_hash\`, \`events_processed\`) VALUES (${orphanCheckpointId}, 1, 999, NULL, 1), (${orphanCheckpointId}, 137, 999, NULL, 1)`,
      )

      let orphansByChain = async () => {
        let rows = await TestClickHouse.query(
          `SELECT \`chain_id\` FROM \`${database}\`.\`envio_checkpoints\` WHERE \`id\` = ${orphanCheckpointId} ORDER BY \`chain_id\` FORMAT TabSeparated`,
        )
        rows->String.trim->String.split("\n")->Array.filter(row => row !== "")
      }

      let planted = await orphansByChain()
      let _ = await indexer.restart(~chains=[ChainId.fromInt(1)], ())
      t.expect((planted, await orphansByChain())).toEqual((["1", "137"], ["137"]))
    },
  )
})
