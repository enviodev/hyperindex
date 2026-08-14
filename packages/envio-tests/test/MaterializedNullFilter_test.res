// `_eq: null` asks for the rows where a value isn't there. It matches both a
// JSON null and a field the source left out, which is what a config author
// means by "null" — deliberately not SQL, where `= NULL` matches nothing.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: materialized-null-filter
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
  # A transaction with no \`to\` is a contract creation.
  creations:
    from: evm.events
    where:
      eventName: Transfer
      transaction:
        to:
          _eq: null
    select:
      id: params.to
      total:
        _sum: params.value
  # The complement, so the two together account for every event.
  calls:
    from: evm.events
    where:
      eventName: Transfer
      transaction:
        to:
          _neq: null
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

const transfer = (transaction: { to?: \`0x\${string}\` }, value: bigint) => ({
  contract: "ERC20" as const,
  event: "Transfer" as const,
  transaction,
  params: { from: bob, to: alice, value },
});

describe("a where comparing against null", () => {
  it("matches the rows whose value isn't there, and its complement", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            transfer({}, 1n), // the field is absent
            transfer({ to: bob }, 10n),
            transfer({ to: undefined }, 100n), // present, holding nothing
          ],
        },
      },
    });

    t.expect({
      creations: await indexer.Creations.getAll(),
      calls: await indexer.Calls.getAll(),
    }).toEqual({
      creations: [{ id: alice, total: 101n, chainId: 1 }],
      calls: [{ id: alice, total: 10n, chainId: 1 }],
    });
  });
});
`,
)
