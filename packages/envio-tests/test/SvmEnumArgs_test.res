let configYaml = `
name: svm-enum-args
ecosystem: svm
chains:
  - id: solana
    start_block: 0
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: Swapper
          program_id: 675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8
          instructions:
            - name: swap
              discriminator: "0x09"
              args:
                - name: side
                  type:
                    enum:
                      - { name: Bid }
                      - { name: Ask }
                - name: mode
                  type:
                    enum:
                      - { name: ExactIn }
                      - { name: Limit, fields: [{ name: price, type: u64 }] }
                      - { name: Empty, fields: [] }
              accounts:
                - source
`

let _ = InternalTestIndexer.fromUserApi(
  ~schema=ApiTypesFixtures.schema,
  ~configYaml,
  ~handlers=`
import { indexer } from "envio";

indexer.onInstruction(
  { program: "Swapper", instruction: "swap", fields: { instruction: ["args"] } },
  async ({ instruction, context }) => {
    const { side, mode } = instruction.args;
    const price = typeof mode === "string" ? 0n : mode.Limit.price;
    context.Account.set({
      id: typeof mode === "string" ? mode : "ask",
      balance: price,
      accountType: side === "Ask" ? "ADMIN" : "USER",
      delegate_id: undefined,
    });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("SVM enum args", () => {
  it("unit variants arrive as strings, payload variants as single-key objects", async (t) => {
    const indexer = createTestIndexer();
    const block = { slot: 5, time: 1 };
    const transaction = { transactionIndex: 0, accountActivities: [] };
    const accountArguments = ["675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8"];
    await indexer.process({
      chains: {
        7565164: {
          simulate: [
            { program: "Swapper", instruction: "swap", path: [0], args: { side: "Bid", mode: "ExactIn" }, accountArguments, block, transaction },
            { program: "Swapper", instruction: "swap", path: [1], args: { side: "Bid", mode: "Empty" }, accountArguments, block, transaction },
            { program: "Swapper", instruction: "swap", path: [2], args: { side: "Ask", mode: { Limit: { price: 7n } } }, accountArguments, block, transaction },
          ],
        },
      },
    });
    t.expect({
      exactIn: (await indexer.Account.getOrThrow("ExactIn")).balance,
      empty: (await indexer.Account.getOrThrow("Empty")).accountType,
      ask: (await indexer.Account.getOrThrow("ask")).balance,
    }).toEqual({ exactIn: 0n, empty: "USER", ask: 7n });
  });
});
`,
)
