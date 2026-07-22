open Vitest

let yaml = `
name: mock-handlers
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`

let schema = `
type Account {
  id: ID!
  balance: BigInt!
}
`

describe("MockIndexerFixture handler type-checking", () => {
  it("accepts handlers that match the generated indexer types", t => {
    let {config} = MockIndexerFixture.fromYaml(
      ~schema,
      ~handlers=`
import { indexer } from "envio";
import type { Address } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  expectType<TypeEqual<typeof event.params.value, bigint>>(true);
  expectType<TypeEqual<typeof event.params.from, Address>>(true);
  context.Account.set({ id: event.params.to, balance: event.params.value });
});
`,
      yaml,
    )
    t.expect(config.name).toBe("mock-handlers")
  })

  it("throws on handlers that reference a nonexistent event", t => {
    t.expect(
      () =>
        MockIndexerFixture.fromYaml(
          ~schema,
          ~handlers=`
import { indexer } from "envio";
indexer.onEvent({ contract: "Token", event: "Nonexistent" }, async () => {});
`,
          yaml,
        )->ignore,
    ).toThrowError("Handler type errors")
  })
})
