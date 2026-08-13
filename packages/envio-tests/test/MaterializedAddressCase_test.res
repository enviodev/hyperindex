// Addresses reach a filter in whatever casing the config author pasted, while
// the decoder writes them in the casing `address_format` picks. Comparing the
// two verbatim never matches, and an empty table is a silent failure — so an
// address literal is normalized to the configured casing while the filter
// compiles. This config leaves `address_format` at its default, checksum.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: materialized-address-case
disable_default_cross_chain: true
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
      srcAddress:
        _eq:
          _literal: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
      params:
        from:
          _eq:
            _literal: "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
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
const bob = Addresses.mockAddresses[2];
const usdc = "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984";

describe("an address literal in a where", () => {
  it("matches the decoder's casing however the literal was written", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "ERC20",
              event: "Transfer",
              srcAddress: usdc,
              // The sender the lowercase literal names, checksummed as the
              // decoder produces it.
              params: { from: Addresses.defaultAddress, to: alice, value: 6n },
            },
            {
              contract: "ERC20",
              event: "Transfer",
              srcAddress: usdc,
              params: { from: bob, to: alice, value: 100n },
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
