// Live test against solana.hypersync.xyz over a pinned slot window holding
// exactly one Wormhole `post_message` call, whose `payload` is a Borsh
// `bytes` arg. Checks the arg and the raw instruction data reach the handler
// as Uint8Arrays with the on-chain bytes, not as hex strings.

let _apiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run the live SVM bytes test",
  )

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: svm-bytes-live
ecosystem: svm
chains:
  - id: solana
    start_block: 420650000
    end_block: 420650200
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: Wormhole
          program_id: worm2ZoG2kUd4vFXhvjh93UUH596ayRfgQ2MgjNMTth
          instructions:
            - name: postMessage
              discriminator: "0x01"
              args:
                - { name: nonce, type: u32 }
                - { name: payload, type: bytes }
                - { name: consistencyLevel, type: u8 }
              accounts:
                - bridge
                - message
                - emitter
                - sequence
                - payer
                - feeCollector
                - clock
                - systemProgram
                - rent
`,
  ~schema=`
type Message {
  id: ID!
  payloadIsUint8Array: Boolean!
  payloadLength: Int!
  payloadHead: String!
  consistencyLevel: Int!
  dataIsUint8Array: Boolean!
  dataLength: Int!
  dataFirstByte: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onInstruction(
  {
    program: "Wormhole",
    instruction: "postMessage",
    fields: { instruction: ["args", "data", "path"], transaction: ["signature"] },
  },
  async ({ instruction, context }) => {
    const payload: Uint8Array = instruction.args.payload;
    context.Message.set({
      id: \`\${instruction.transaction.signature}:\${instruction.path.join(".")}\`,
      payloadIsUint8Array: payload instanceof Uint8Array,
      payloadLength: payload.length,
      payloadHead: Buffer.from(payload.subarray(0, 4)).toString("hex"),
      consistencyLevel: instruction.args.consistencyLevel,
      dataIsUint8Array: instruction.data instanceof Uint8Array,
      dataLength: instruction.data.length,
      dataFirstByte: instruction.data[0] ?? -1,
    });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("SVM bytes args (live)", () => {
  it(
    "decodes a Borsh bytes arg as a Uint8Array",
    async (t) => {
      const indexer = createTestIndexer();
      await indexer.process({ chains: { 7565164: { endBlock: 420650200 } } });

      const messages = await indexer.Message.getAll();
      t.expect(
        messages.map(({ id: _, ...rest }) => rest),
      ).toEqual([
        {
          payloadIsUint8Array: true,
          payloadLength: 217,
          payloadHead: "9945ff10",
          consistencyLevel: 1,
          dataIsUint8Array: true,
          dataLength: 227,
          dataFirstByte: 1,
        },
      ]);
    },
    300_000,
  );
});
`,
)
