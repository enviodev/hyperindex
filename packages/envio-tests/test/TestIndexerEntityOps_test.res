// Direct `indexer.<Entity>` access on a test indexer — the store a test seeds
// and reads outside of `process()`, and the guards that keep it out of a run.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: entity-ops
chains:
  - id: 1
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "EmptyEvent()"
`,
  ~schema=`
enum AccountType {
  USER
  ADMIN
}

type User {
  id: ID!
  address: String!
  updatesCountOnUserForTesting: Int!
  gravatar: Gravatar
  accountType: AccountType!
}

type Gravatar {
  id: ID!
  displayName: String!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "EmptyEvent" }, async () => {});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type User } from "envio";

const user: User = {
  id: "test-user-1",
  address: "0x1234",
  updatesCountOnUserForTesting: 5,
  gravatar_id: undefined,
  accountType: "USER",
};

describe("TestIndexer entity operations", () => {
  it("set stores an entity that get retrieves", async (t) => {
    const indexer = createTestIndexer();
    indexer.User.set(user);

    t.expect(await indexer.User.get("test-user-1")).toEqual(user);
  });

  it("get returns undefined for an entity that was never set", async (t) => {
    const indexer = createTestIndexer();

    t.expect(await indexer.User.get("non-existent")).toBe(undefined);
  });

  it("set overwrites an entity already under that id", async (t) => {
    const indexer = createTestIndexer();
    const updated: User = {
      id: "test-user-1",
      address: "0x5678",
      updatesCountOnUserForTesting: 10,
      gravatar_id: "gravatar-1",
      accountType: "ADMIN",
    };

    indexer.User.set(user);
    indexer.User.set(updated);

    t.expect(await indexer.User.get("test-user-1")).toEqual(updated);
  });

  // Every entity crossing the store boundary is copied, so a handler holding
  // on to one and mutating it later can't rewrite what the store holds.
  it("mutating an entity across the set/get boundary leaves the store intact", async (t) => {
    const indexer = createTestIndexer();
    const original: User = { ...user, id: "0", address: "existing" };
    indexer.User.set(original);

    Object.assign(original, { address: "mutated-after-set" });
    Object.assign(await indexer.User.getOrThrow("0"), { address: "mutated-after-getOrThrow" });
    Object.assign((await indexer.User.get("0"))!, { address: "mutated-after-get" });
    (await indexer.User.getAll()).forEach((u) =>
      Object.assign(u, { address: "mutated-after-getAll" })
    );

    t.expect(await indexer.User.getAll()).toEqual([{ ...user, id: "0", address: "existing" }]);
  });

  it("get throws while process() is running", (t) => {
    const indexer = createTestIndexer();
    indexer.process({ chains: { 1: { startBlock: 1, endBlock: 100 } } });

    t.expect(() => indexer.User.get("test-user-1")).toThrowError(
      "Cannot call User.get() while indexer.process() is running. Wait for process() to complete before accessing entities directly."
    );
  });

  it("set throws while process() is running", (t) => {
    const indexer = createTestIndexer();
    indexer.process({ chains: { 1: { startBlock: 1, endBlock: 100 } } });

    t.expect(() => indexer.User.set(user)).toThrowError(
      "Cannot call User.set() while indexer.process() is running. Wait for process() to complete before modifying entities directly."
    );
  });

  it("contract addresses throw while process() is running", (t) => {
    const indexer = createTestIndexer();
    indexer.process({ chains: { 1: { startBlock: 1, endBlock: 100 } } });

    t.expect(() => indexer.chains[1].Gravatar.addresses).toThrowError(
      "Cannot access Gravatar.addresses while indexer.process() is running. Wait for process() to complete before reading contract addresses."
    );
  });
});
`,
)
