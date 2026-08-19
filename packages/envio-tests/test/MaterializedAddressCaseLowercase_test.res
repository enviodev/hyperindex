// The other direction of MaterializedAddressCase_test: with
// `address_format: lowercase` the decoder writes lowercase, so a checksummed
// literal — the spelling most block explorers hand out — is what needs
// normalizing.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: materialized-address-case-lowercase
disable_default_cross_chain: true
address_format: lowercase
contracts:
  - name: ERC20
    events:
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
tables:
  receipts:
    from: evm.events
    where:
      eventName: Transfer
      params:
        from:
          _eq:
            _literal: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    select:
      id: params.to
      total:
        _sum: params.value
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;
const alice = Addresses.mockAddresses[1];
// Addresses.defaultAddress, as the decoder writes it under this format.
const sender = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266";

describe("an address literal under address_format: lowercase", () => {
  it("matches a lowercase decoded address", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "ERC20",
              event: "Transfer",
              params: { from: sender, to: alice, value: 6n },
            },
          ],
        },
      },
    });

    t.expect(await indexer.Receipts.getAll()).toEqual([{ id: alice, total: 6n, chainId: 1 }]);
  });
});
`,
)
