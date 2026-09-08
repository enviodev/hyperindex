// The four shapes a config.yaml row can now ask for, through the user API.
// The empty prefix is what every call carries, so a row dispatching on it takes
// the whole program — SPL Memo's shape. `accounts` and `args` are independent:
// one names slots the call already carries, the other attaches a decoder, and a
// row asks for either without the other. Omitting `args` attaches no decoder;
// writing `args: []` attaches an empty one, which asserts the instruction takes
// no arguments and so indexes only the calls that carry none.

let memoId = "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr"
let namesId = "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8"
let argsId = "9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin"
let bareId = "SysvarC1ock11111111111111111111111111111111"
let sourcePk = "So11111111111111111111111111111111111111112"
let destinationPk = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"

let _ = InternalTestIndexer.fromUserApi(
  ~schema=`
type Call {
  id: ID!
  discriminator: String!
}
type Named {
  id: ID!
  source: String!
}
type Decoded {
  id: ID!
  amount: BigInt!
  firstAccount: String!
}
type Bare {
  id: ID!
}
`,
  ~configYaml=`
name: svm-instruction-layout
ecosystem: svm
chains:
  - id: solana
    start_slot: 0
    hypersync_config:
      url: https://solana.hypersync.xyz
programs:
  - name: Memo
    program_id: ${memoId}
    instructions:
      - name: anyCall
        discriminator: "0x"
  - name: NamesOnly
    program_id: ${namesId}
    instructions:
      - name: transfer
        discriminator: "0x01"
        accounts:
          - source
  - name: ArgsOnly
    program_id: ${argsId}
    instructions:
      - name: transfer
        discriminator: "0x02"
        args:
          - { name: amount, type: u64 }
  - name: NoArgs
    program_id: ${bareId}
    instructions:
      - name: tick
        discriminator: "0x03"
        args: []
`,
  ~handlers=`
import { indexer } from "envio";

// A row on the empty prefix declares no layout, so \`args\` is \`never\` and the
// account names are whatever the call carried.
indexer.onInstruction(
  { program: "Memo", instruction: "anyCall" },
  async ({ instruction, context }) => {
    context.Call.set({
      id: instruction.block.slot.toString(),
      discriminator: instruction.discriminator,
    });
  },
);

indexer.onInstruction(
  { program: "NamesOnly", instruction: "transfer", fields: { instruction: ["accounts"] } },
  async ({ instruction, context }) => {
    instruction.accounts.source.address satisfies string;
    context.Named.set({
      id: instruction.block.slot.toString(),
      source: instruction.accounts.source.address,
    });
  },
);

indexer.onInstruction(
  {
    program: "ArgsOnly",
    instruction: "transfer",
    fields: { instruction: ["args", "accountArguments"] },
  },
  async ({ instruction, context }) => {
    instruction.args.amount satisfies bigint;
    context.Decoded.set({
      id: instruction.block.slot.toString(),
      amount: instruction.args.amount,
      firstAccount: instruction.accountArguments[0]!,
    });
  },
);

// An empty layout is still a layout, so \`args\` is selectable and decodes to an
// empty object — where a row that omits \`args\` types it \`never\`.
indexer.onInstruction(
  { program: "NoArgs", instruction: "tick", fields: { instruction: ["args"] } },
  async ({ instruction, context }) => {
    instruction.args satisfies {};
    context.Bare.set({ id: instruction.block.slot.toString() });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("SVM instruction layout through the user API", () => {
  // Nothing was dispatched on, so there is no prefix to report and the whole
  // data is what the call was keyed by — a different value per call, where a
  // row with a prefix reports the same one every time.
  it("reports the whole data as the key of a row on the empty prefix", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        7565164: {
          simulate: [
            { program: "Memo", instruction: "anyCall", slot: 1, data: new Uint8Array([0x09, 0xab]) },
            { program: "Memo", instruction: "anyCall", slot: 2, data: new Uint8Array([0xff]) },
          ],
        },
      },
    });
    t.expect([
      await indexer.Call.getOrThrow("1"),
      await indexer.Call.getOrThrow("2"),
    ]).toEqual([
      { id: "1", discriminator: "0x09ab" },
      { id: "2", discriminator: "0xff" },
    ]);
  });

  // \`accounts\` alone names the slots; nothing decodes the payload.
  it("names accounts on a row that declares no args", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        7565164: {
          simulate: [
            {
              program: "NamesOnly",
              instruction: "transfer",
              slot: 1,
              accounts: { source: { address: "${sourcePk}" } },
            },
          ],
        },
      },
    });
    t.expect(await indexer.Named.getOrThrow("1")).toEqual({ id: "1", source: "${sourcePk}" });
  });

  // \`args\` alone attaches the decoder; the slots stay positional.
  it("decodes args on a row that names no accounts", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        7565164: {
          simulate: [
            {
              program: "ArgsOnly",
              instruction: "transfer",
              slot: 1,
              args: { amount: 42n },
              accountArguments: ["${destinationPk}"],
            },
          ],
        },
      },
    });
    t.expect(await indexer.Decoded.getOrThrow("1")).toEqual({
      id: "1",
      amount: 42n,
      firstAccount: "${destinationPk}",
    });
  });

  // Writing the empty layout is an assertion about the call, not a no-op: it
  // says the instruction takes no arguments.
  it("selects args as an empty object on a row that declares an empty layout", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        7565164: {
          simulate: [{ program: "NoArgs", instruction: "tick", slot: 1, args: {} }],
        },
      },
    });
    t.expect(await indexer.Bare.getOrThrow("1")).toEqual({ id: "1" });
  });
});
`,
)
