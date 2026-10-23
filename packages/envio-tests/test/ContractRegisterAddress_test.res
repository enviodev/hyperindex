// contractRegister: sync, async, and the address validation it applies before
// a dynamic contract joins the run.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: contract-register-address
chains:
  - id: 1
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "FactoryEvent(address indexed contract, string testCase)"
          - event: "Register(string addressInput)"
      - name: SimpleNft
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 indexed tokenId)
      - name: OtherNft
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 indexed tokenId)
`,
  ~schema=`
type Probe {
  id: ID!
}
`,
  ~handlers=`
import { indexer, type Address } from "envio";

indexer.contractRegister({ contract: "Gravatar", event: "FactoryEvent" }, async ({ event, context }) => {
  switch (event.params.testCase) {
    case "syncRegistration":
      context.chain.SimpleNft.add(event.params.contract);
      return;
    case "asyncRegistration":
      await new Promise<void>((resolve) =>
        setTimeout(() => {
          context.chain.SimpleNft.add(event.params.contract);
          resolve();
        }, 0)
      );
      return;
    // The macrotask outlives the register call, so the context it captured is
    // already closed by the time it runs.
    case "throwOnHangingRegistration":
      setTimeout(() => {
        try {
          context.chain.SimpleNft.add(event.params.contract);
        } catch {}
      }, 0);
      return;
    case "registersTwice":
      context.chain.SimpleNft.add(event.params.contract);
      context.chain.SimpleNft.add(event.params.contract);
      return;
    case "registersForTwoContracts":
      context.chain.SimpleNft.add(event.params.contract);
      context.chain.OtherNft.add(event.params.contract);
      return;
  }
});

indexer.contractRegister({ contract: "Gravatar", event: "Register" }, async ({ event, context }) => {
  context.chain.SimpleNft.add(event.params.addressInput as Address);
});

indexer.onEvent({ contract: "SimpleNft", event: "Transfer" }, async () => {});
indexer.onEvent({ contract: "OtherNft", event: "Transfer" }, async () => {});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Address } from "envio";

const dcAddress: Address = "0x1234567890123456789012345678901234567890";

const run = (
  indexer: ReturnType<typeof createTestIndexer>,
  params: { contract: Address; testCase: string }
) =>
  indexer.process({
    chains: {
      1: {
        startBlock: 1,
        endBlock: 100,
        simulate: [
          { contract: "Gravatar", event: "FactoryEvent", params, block: { number: 2 } },
        ],
      },
    },
  });

const register = (addressInput: string) =>
  createTestIndexer().process({
    chains: {
      1: {
        startBlock: 1,
        endBlock: 100,
        simulate: [{ contract: "Gravatar", event: "Register", params: { addressInput }, block: { number: 2 } }],
      },
    },
  });

describe("contractRegister address handling", () => {
  it("registers a dynamic contract from a sync register", async (t) => {
    const indexer = createTestIndexer();
    const result = await run(indexer, { contract: dcAddress, testCase: "syncRegistration" });

    t.expect(result.changes[0]?.addresses).toEqual({
      sets: [{ address: dcAddress, contract: "SimpleNft" }],
    });
  });

  it("registers a dynamic contract from an async register", async (t) => {
    const indexer = createTestIndexer();
    const result = await run(indexer, { contract: dcAddress, testCase: "asyncRegistration" });

    t.expect(result.changes[0]?.addresses).toEqual({
      sets: [{ address: dcAddress, contract: "SimpleNft" }],
    });
  });

  it("drops a registration made from an unawaited macrotask", async (t) => {
    const indexer = createTestIndexer();
    const result = await run(indexer, { contract: dcAddress, testCase: "throwOnHangingRegistration" });

    t.expect(result.changes[0]?.addresses).toBe(undefined);
  });

  it("checksums any casing of a valid address", async (t) => {
    const inputs = [
      "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
      "0xF39FD6E51AAD88F6F4CE6AB8827279CFFFB92266",
      "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
      "0xF39fd6e51aad88F6F4ce6aB8827279cffFb92266",
    ];
    const registered = [];
    for (const input of inputs) {
      registered.push((await register(input)).changes[0]?.addresses);
    }

    t.expect(registered).toEqual(
      inputs.map(() => ({
        sets: [{ address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266", contract: "SimpleNft" }],
      }))
    );
  });

  for (const input of [
    "invalid-address",
    "0x12",
    "f39fd6e51aad88f6f4ce6ab8827279cfffb92266",
    "0Xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
    "0xg39fd6e51aad88f6f4ce6ab8827279cfffb92266",
    "0xf39fd6e51aad88f6f4ce6ab8827279cfffb9226600",
  ]) {
    it(\`rejects \${input}\`, async (t) => {
      await t.expect(register(input)).rejects.toThrow(
        \`Address "\${input}" is invalid. Expected a 20-byte hex string starting with 0x.\`
      );
    });
  }

  it("keeps the same address registered twice for one contract a single registration", async (t) => {
    const indexer = createTestIndexer();
    const result = await run(indexer, { contract: dcAddress, testCase: "registersTwice" });

    t.expect(result.changes[0]?.addresses).toEqual({
      sets: [{ address: dcAddress, contract: "SimpleNft" }],
    });
  });

  it("registers one address once per contract that claims it", async (t) => {
    const indexer = createTestIndexer();
    const result = await run(indexer, {
      contract: dcAddress,
      testCase: "registersForTwoContracts",
    });

    t.expect(result.changes[0]?.addresses).toEqual({
      sets: [
        { address: dcAddress, contract: "SimpleNft" },
        { address: dcAddress, contract: "OtherNft" },
      ],
    });
  });
});
`,
)
