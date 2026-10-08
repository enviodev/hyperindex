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
}
`,
)

describe("Restarting onto a schema an older envio wrote", () => {
  scenario->Scenario.it("refuses, naming the older envio version", ~sources=[{chain: 1}], async (
    ~t,
    ~indexer,
    ~source as _,
  ) => {
    let {sql, pgSchema} = indexer.pg
    let _ = await sql->Sql.query(`DROP TABLE "${pgSchema}"."envio_contracts";`)

    let message = switch await indexer.restart() {
    | _ => "the restart to fail, but it succeeded"
    | exception JsExn(error) => error->JsExn.message->Option.getOr("")
    }

    t.expect(
      message->String.includes("storage was initialized by an older envio version"),
      ~message,
    ).toBe(true)
  })
})
