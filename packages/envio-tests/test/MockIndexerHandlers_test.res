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

describe("InternalTestIndexer handler type-checking", () => {
  it("accepts handlers that match the generated indexer types", t => {
    let {config} = InternalTestIndexer.fromUserApi(
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
      ~configYaml=yaml,
    )
    t.expect(config.name).toBe("mock-handlers")
  })

  it("throws the exact diagnostic on a nonexistent event", t => {
    t.expect(
      () =>
        InternalTestIndexer.fromUserApi(
          ~schema,
          ~handlers=`
import { indexer } from "envio";
indexer.onEvent({ contract: "Token", event: "Nonexistent" }, async () => {});
`,
          ~configYaml=yaml,
        )->ignore,
    ).toThrowError(`Type '"Nonexistent"' is not assignable to type '"Transfer"'`)
  })
})
