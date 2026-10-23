// address_format: lowercase — what contractRegister does with a user-supplied
// address. The checksum counterpart lives in ContractRegisterAddress_test.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: address-lowercase
address_format: lowercase
chains:
  - id: 1
    start_block: 1
    contracts:
      - name: Factory
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "Register(string addressInput)"
      - name: SimpleNft
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 indexed tokenId)
      - name: Token
        address:
          - "0x1E645469f354BB4F5c8a05B3b30A929361cf77eC"
          - "0xA2F6E6029638CCB484A2CCB6414499AD3E825CAC"
        events:
          - event: Approval(address indexed owner)
`,
  ~schema=`
type Probe {
  id: ID!
}
`,
  ~handlers=`
import { indexer, type Address } from "envio";

indexer.contractRegister({ contract: "Factory", event: "Register" }, async ({ event, context }) => {
  context.chain.SimpleNft.add(event.params.addressInput as Address);
});

indexer.onEvent({ contract: "SimpleNft", event: "Transfer" }, async () => {});
indexer.onEvent({ contract: "Token", event: "Approval" }, async ({ event, context }) => {
  context.Probe.set({ id: event.srcAddress });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const register = (addressInput: string) =>
  createTestIndexer().process({
    chains: {
      1: {
        startBlock: 1,
        endBlock: 100,
        simulate: [{ contract: "Factory", event: "Register", params: { addressInput }, block: { number: 2 } }],
      },
    },
  });

describe("contractRegister with address_format: lowercase", () => {
  it("lowercases config addresses and routes a checksummed srcAddress to them", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Token",
              event: "Approval",
              srcAddress: "0x1E645469f354Bb4F5c8A05b3B30a929361cF77ec",
              params: { owner: "0x1234567890123456789012345678901234567890" },
              block: { number: 2 },
            },
          ],
        },
      },
    });

    t.expect({
      addresses: indexer.chains[1].Token.addresses,
      probes: await indexer.Probe.getAll(),
    }).toEqual({
      addresses: [
        "0x1e645469f354bb4f5c8a05b3b30a929361cf77ec",
        "0xa2f6e6029638ccb484a2ccb6414499ad3e825cac",
      ],
      probes: [{ id: "0x1e645469f354bb4f5c8a05b3b30a929361cf77ec" }],
    });
  });

  it("lowercases any casing of a valid address", async (t) => {
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
        sets: [{ address: "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266", contract: "SimpleNft" }],
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
});
`,
)
