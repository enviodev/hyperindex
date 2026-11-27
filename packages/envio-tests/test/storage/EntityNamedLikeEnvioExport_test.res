// An entity is exported from `envio` under its own name unless that name is
// already an `envio` export; then it is reached only through `Entity<"Name">`.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: envio-export-names
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
        events:
          - event: Transfer(address indexed to, uint256 value)
`,
  ~schema=`
type Hex {
  id: ID!
}
type Address {
  id: ID!
  value: BigInt!
}
type enum {
  id: ID!
}
type Account {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  context.Hex.set({ id: event.params.to });
  context.Address.set({ id: event.params.to, value: event.params.value });
  context.Enum.set({ id: event.params.to });
  context.Account.set({ id: event.params.to });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { expectType, type TypeEqual } from "ts-expect";
import {
  createTestIndexer,
  type Account,
  type Address,
  type Entity,
  type Hex,
  type StrictHex,
  TestHelpers,
} from "envio";

const { Addresses } = TestHelpers;

expectType<
  TypeEqual<
    [Account, Hex, StrictHex, Address],
    [Entity<"Account">, string, \`0x\${string}\`, \`0x\${string}\`]
  >
>(true);

describe("entities named after envio exports", () => {
  it("indexes entities named Hex, Address and enum", async (t) => {
    const indexer = createTestIndexer();
    const to = Addresses.defaultAddress;
    const hex: Hex = to;

    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Token", event: "Transfer", params: { to, value: 5n } },
          ],
        },
      },
    });

    const expected: [Entity<"Hex">, Entity<"Address">, Entity<"Enum">] = [
      { id: hex },
      { id: to, value: 5n },
      { id: to },
    ];
    t.expect([
      await indexer.Hex.getOrThrow(to),
      await indexer.Address.getOrThrow(to),
      await indexer.Enum.getOrThrow(to),
    ]).toEqual(expected);
  });
});
`,
)
