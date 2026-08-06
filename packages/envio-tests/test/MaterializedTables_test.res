// The ERC-20 template's `tables` config, with no schema.graphql and no
// handlers: the config alone is the indexer. Exercises keyed overwrite,
// two events, a union, an aggregate, references, zero-value row creation and
// multiple writes per event.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: erc20-indexer
disable_default_cross_chain: true
contracts:
  - name: ERC20
    events:
      - event: "Approval(address indexed owner, address indexed spender, uint256 value)"
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
tables:
  accounts:
    with:
      balance_changes:
        # Approval owners should exist even if they have never transferred.
        - from: evm.events
          where:
            contractName: ERC20
            eventName: Approval
          select:
            account: params.owner
            delta: 0
        # Also create the spender because approvals.spender is non-null.
        - from: evm.events
          where:
            contractName: ERC20
            eventName: Approval
          select:
            account: params.spender
            delta: 0
        # Debit the sender.
        - from: evm.events
          where:
            contractName: ERC20
            eventName: Transfer
          select:
            account: params.from
            delta:
              _negate: params.value
        # Credit the receiver.
        - from: evm.events
          where:
            contractName: ERC20
            eventName: Transfer
          select:
            account: params.to
            delta: params.value
    from: balance_changes
    select:
      id: account
      balance:
        _sum: delta
      approvals:
        _derived_from: approvals.owner
  approvals:
    from: evm.events
    where:
      contractName: ERC20
      eventName: Approval
    select:
      id:
        _concat:
          separator: "-"
          values:
            - params.owner
            - params.spender
      amount: params.value
      owner:
        _ref:
          table: accounts
          id: params.owner
      spender:
        _ref:
          table: accounts
          id: params.spender
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers, type Accounts, type Approvals } from "envio";

const { Addresses } = TestHelpers;
const alice: string = Addresses.mockAddresses[0];
const bob: string = Addresses.mockAddresses[1];

const transfer = (from: string, to: string, value: bigint) => ({
  contract: "ERC20" as const,
  event: "Transfer" as const,
  params: { from, to, value },
});

const approval = (owner: string, spender: string, value: bigint) => ({
  contract: "ERC20" as const,
  event: "Approval" as const,
  params: { owner, spender, value },
});

const process = (indexer: ReturnType<typeof createTestIndexer>, simulate: unknown[]) =>
  indexer.process({ chains: { 1: { simulate: simulate as never } } });

describe("Materialized ERC-20 tables", () => {
  it("debits the sender and credits the receiver", async (t) => {
    const indexer = createTestIndexer();
    await process(indexer, [transfer(alice, bob, 5n)]);

    t.expect(await indexer.Accounts.getAll()).toEqual([
      { id: alice, balance: -5n, chainId: 1 },
      { id: bob, balance: 5n, chainId: 1 },
    ]);
  });

  it("accumulates across events, so a balance is the sum of its contributions", async (t) => {
    const indexer = createTestIndexer();
    await process(indexer, [transfer(alice, bob, 5n), transfer(bob, alice, 2n)]);

    t.expect(await indexer.Accounts.getAll()).toEqual([
      { id: alice, balance: -3n, chainId: 1 },
      { id: bob, balance: 3n, chainId: 1 },
    ]);
  });

  // A self-transfer contributes a debit and a credit to one row; summing
  // cancels them instead of the two writes racing.
  it("nets a self-transfer to zero", async (t) => {
    const indexer = createTestIndexer();
    await process(indexer, [transfer(alice, alice, 7n)]);

    t.expect(await indexer.Accounts.getAll()).toEqual([{ id: alice, balance: 0n, chainId: 1 }]);
  });

  it("creates both sides of an approval with a zero balance, and the approval row", async (t) => {
    const indexer = createTestIndexer();
    await process(indexer, [approval(alice, bob, 100n)]);

    const expected: {
      accounts: (Accounts & { chainId: number })[];
      approvals: (Approvals & { chainId: number })[];
    } = {
      accounts: [
        { id: alice, balance: 0n, chainId: 1 },
        { id: bob, balance: 0n, chainId: 1 },
      ],
      approvals: [
        {
          id: \`\${alice}-\${bob}\`,
          amount: 100n,
          owner_id: alice,
          spender_id: bob,
          chainId: 1,
        },
      ],
    };
    t.expect({
      accounts: await indexer.Accounts.getAll(),
      approvals: await indexer.Approvals.getAll(),
    }).toEqual(expected);
  });

  it("overwrites an approval by id and leaves the balance alone", async (t) => {
    const indexer = createTestIndexer();
    await process(indexer, [
      transfer(alice, bob, 5n),
      approval(alice, bob, 100n),
      approval(alice, bob, 42n),
    ]);

    t.expect({
      approvals: await indexer.Approvals.getAll(),
      accounts: await indexer.Accounts.getAll(),
    }).toEqual({
      approvals: [
        { id: \`\${alice}-\${bob}\`, amount: 42n, owner_id: alice, spender_id: bob, chainId: 1 },
      ],
      accounts: [
        { id: alice, balance: -5n, chainId: 1 },
        { id: bob, balance: 5n, chainId: 1 },
      ],
    });
  });
});
`,
)
