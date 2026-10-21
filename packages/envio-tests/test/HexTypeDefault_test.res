open Vitest

describe("strict_hex_type default", () => {
  it("keeps hex-string values as plain string and accepts a plain string", _ =>
    InternalTestIndexer.fromUserApi(
      ~schema=`
type Blob {
  id: ID!
  data: Bytes!
}
`,
      ~configYaml=`
name: hex-default
contracts:
  - name: Registry
    events:
      - event: Stored(bytes32 indexed key, bytes data)
        field_selection:
          block_fields:
            - parentHash
            - uncles
          transaction_fields:
            - hash
            - input
            - r
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Registry
        address: "0x0000000000000000000000000000000000000001"
`,
      ~handlers=`
import { createTestIndexer, indexer } from "envio";
import type {
  Blob,
  EvmAllBlockFields,
  EvmAllTransactionFields,
  EvmEvent,
  Hex,
  HexString,
} from "envio";
import { expectType, type TypeEqual } from "ts-expect";

type Stored = EvmEvent<"Registry", "Stored">;
expectType<
  TypeEqual<
    {
      hex: Hex;
      hexString: HexString;
      key: Stored["params"]["key"];
      data: Stored["params"]["data"];
      blockHash: Stored["block"]["hash"];
      parentHash: Stored["block"]["parentHash"];
      uncles: Stored["block"]["uncles"];
      transactionHash: Stored["transaction"]["hash"];
      input: Stored["transaction"]["input"];
      r: Stored["transaction"]["r"];
      allBlockHash: EvmAllBlockFields["hash"];
      allTransactionHash: EvmAllTransactionFields["hash"];
      blobData: Blob["data"];
    },
    {
      hex: \`0x\${string}\`;
      hexString: string;
      key: string;
      data: string;
      blockHash: string;
      parentHash: string;
      uncles: readonly string[] | undefined;
      transactionHash: string;
      input: string;
      r: string | undefined;
      allBlockHash: string;
      allTransactionHash: string;
      blobData: string;
    }
  >
>(true);

const plain: string = "0x01";

if (0) {
  indexer.onEvent(
    { contract: "Registry", event: "Stored", where: { params: { key: plain } } },
    async ({ context }) => {
      context.Blob.set({ id: "1", data: plain });
    },
  );

  const testIndexer = createTestIndexer();
  void testIndexer.process({
    chains: {
      1: {
        simulate: [
          { contract: "Registry", event: "Stored", params: { key: plain, data: plain } },
        ],
      },
    },
  });
}
`,
    )->ignore
  )
})
