let sourceAddr = "So11111111111111111111111111111111111111112"
let destAddr = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
let closedAddr = "9n4nbM75f5Ui33ZbPYXn59EwSgE8CGsHtAeTH5YFeJ9E"
let mintAddr = "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"
let ownerAddr = "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8"

let _ = InternalTestIndexer.fromUserApi(
  ~schema=ApiTypesFixtures.schema,
  ~configYaml=`
name: svm-e2e
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
                - { name: amountIn, type: u64 }
                - { name: minAmountOut, type: u64 }
              accounts:
                - source
                - destination
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onInstruction(
  {
    program: "Swapper",
    instruction: "swap",
    fields: {
      instruction: ["args", "accounts", "accountArguments", "programId", "data", "path", "isInner"],
      transaction: ["signature", "accountKeys"],
      accountActivity: [
        "transactionAccountIndex",
        "lamports.pre",
        "lamports.post",
        "token.mint",
        "token.owner",
        "token.decimals",
        "token.preAmount",
        "token.postAmount",
      ],
      block: ["hash", "time"],
      log: ["kind", "message"],
    },
  },
  async ({ instruction, context }) => {
    const source = instruction.accounts.source;
    const destination = instruction.accounts.destination;
    const opened = instruction.transaction.accountActivities.find(
      (row) => row.address === source.address,
    );
    const closed = instruction.transaction.accountActivities.find(
      (row) => row.address === "${closedAddr}",
    );
    const account = (
      id: string,
      balance: bigint,
      accountType: "ADMIN" | "USER",
    ) => context.Account.set({ id, balance, accountType, delegate_id: undefined });
    account("join", source.activity === opened ? 1n : 0n, destination.activity === undefined ? "USER" : "ADMIN");
    account("opened-post", opened?.token?.postAmount ?? 0n, opened?.token?.preAmount === undefined ? "USER" : "ADMIN");
    account("closed-pre", closed?.token?.preAmount ?? 0n, closed?.token?.postAmount === undefined ? "USER" : "ADMIN");
    account("shape", BigInt(instruction.transaction.accountActivities.length), opened?.lamports === undefined ? "USER" : "ADMIN");
    account("payload", BigInt(instruction.path[0] ?? -1), instruction.discriminator === "0x09" && instruction.data instanceof Uint8Array && instruction.data.length === 1 && instruction.data[0] === 9 ? "USER" : "ADMIN");
    account("time", BigInt(instruction.block.time), instruction.logs.length === 0 ? "USER" : "ADMIN");
    account("args", instruction.args.amountIn, typeof instruction.args.minAmountOut === "bigint" ? "USER" : "ADMIN");
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const sourceAddr = "${sourceAddr}";
const destAddr = "${destAddr}";
const closedAddr = "${closedAddr}";
const mintAddr = "${mintAddr}";
const ownerAddr = "${ownerAddr}";

describe("SVM instruction process e2e", () => {
  it("joins activity onto named accounts and keeps payload fields", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        7565164: {
          simulate: [
            {
              program: "Swapper",
              instruction: "swap",
              path: [0],
              args: { amountIn: 18446744073709551615n, minAmountOut: 1n },
              accountArguments: [sourceAddr, destAddr],
              block: { slot: 5, time: 1_700_000_000 },
              transaction: {
                transactionIndex: 0,
                accountActivities: [
                  {
                    address: sourceAddr,
                    transactionAccountIndex: 0,
                    token: {
                      mint: mintAddr,
                      owner: ownerAddr,
                      decimals: 6,
                      preAmount: undefined,
                      postAmount: 3000000000n,
                    },
                  },
                  {
                    address: closedAddr,
                    transactionAccountIndex: 2,
                    token: {
                      mint: mintAddr,
                      owner: ownerAddr,
                      decimals: 9,
                      preAmount: 700n,
                      postAmount: undefined,
                    },
                  },
                ],
              },
            },
          ],
        },
      },
    });

    t.expect({
      sameObject: (await indexer.Account.getOrThrow("join")).balance,
      destUnset: (await indexer.Account.getOrThrow("join")).accountType,
      openedPost: (await indexer.Account.getOrThrow("opened-post")).balance,
      openedPreUnset: (await indexer.Account.getOrThrow("opened-post")).accountType,
      closedPre: (await indexer.Account.getOrThrow("closed-pre")).balance,
      closedPostUnset: (await indexer.Account.getOrThrow("closed-pre")).accountType,
      activityCount: (await indexer.Account.getOrThrow("shape")).balance,
      lamportsUnset: (await indexer.Account.getOrThrow("shape")).accountType,
      path: (await indexer.Account.getOrThrow("payload")).balance,
      discriminator: (await indexer.Account.getOrThrow("payload")).accountType,
      time: (await indexer.Account.getOrThrow("time")).balance,
      emptyLogs: (await indexer.Account.getOrThrow("time")).accountType,
      argsAmountIn: (await indexer.Account.getOrThrow("args")).balance,
      argsBigint: (await indexer.Account.getOrThrow("args")).accountType,
    }).toEqual({
      sameObject: 1n,
      destUnset: "USER",
      openedPost: 3000000000n,
      openedPreUnset: "USER",
      closedPre: 700n,
      closedPostUnset: "USER",
      activityCount: 2n,
      lamportsUnset: "USER",
      path: 0n,
      discriminator: "USER",
      time: 1_700_000_000n,
      emptyLogs: "USER",
      argsAmountIn: 18446744073709551615n,
      argsBigint: "USER",
    });
  });
});
`,
)
