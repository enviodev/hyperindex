// A Uint8Array id is an object, so every lookup has to match it by its bytes,
// never by reference: the id the test passes is a fresh array each time.
// Per-chain, because that's the test indexer's path that compares ids directly
// instead of through a string key.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: bytes-id-test-indexer
bytes_type: uint8array
disable_default_cross_chain: true
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`,
  ~schema=`
type Token {
  id: Bytes!
  transfers: Int!
}
type Holder {
  id: ID!
  token: Token!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  const id = new Uint8Array([0xaa, Number(event.params.value)]);
  const existing = await context.Token.get(id);
  context.Token.set({ id, transfers: (existing?.transfers ?? 0) + 1 });
  context.Holder.set({ id: event.params.to, token_id: id });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Token, TestHelpers } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

const { Addresses } = TestHelpers;

expectType<TypeEqual<Token["id"], Uint8Array>>(true);

const transfer = (value: bigint) => ({
  contract: "Token" as const,
  event: "Transfer" as const,
  params: { from: Addresses.mockAddresses[1], to: Addresses.defaultAddress, value },
});

describe("Bytes entity id through the test indexer", () => {
  it("loads a Uint8Array id written by an earlier process", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [transfer(1n)] } } });
    await indexer.process({ chains: { 1: { simulate: [transfer(1n)] } } });

    const id = new Uint8Array([0xaa, 1]);
    t.expect({
      token: await indexer.Token.get(id),
      holders: await indexer.Holder.getWhere({ token_id: { _eq: id } }),
    }).toEqual({
      token: { id, transfers: 2, chainId: 1 },
      holders: [{ id: Addresses.defaultAddress, token_id: id, chainId: 1 }],
    });
  });
});
`,
)
