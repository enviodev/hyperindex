import { indexer, type SvmOnSlotContext } from "envio";

const STATS_ID = "global";

// Instructions that only move tokens between accounts. Everything else in the
// matched set changes a mint's circulating amount (mint/burn) or moves an
// amount without a counterparty (closeAccount, syncNative, the Token-2022
// extensions), so a transaction carrying one is not expected to sum to zero.
//
// Only on classic SPL Token, though: a Token-2022 mint can carry a transfer
// fee, and the withheld part lands in the destination's withheld field rather
// than its amount, so even a plain transferChecked loses amount across the two
// sides.
const CONSERVING = new Set(["transfer", "transferChecked"]);
const conservesAmount = (programName: string, instructionName: string): boolean =>
  programName === "SplToken" && CONSERVING.has(instructionName);

const fields = {
  transaction: ["signature", "transactionIndex", "success"],
  accountActivity: [
    "address",
    "token.mint",
    "token.owner",
    "token.decimals",
    "token.preAmount",
    "token.postAmount",
  ],
} as const;

type LedgerTx = {
  signature: string;
  transactionIndex: number;
  success: boolean;
  accountActivities: readonly {
    address: string;
    token:
      | {
          mint: string;
          owner: string;
          decimals: number;
          preAmount: bigint | undefined;
          postAmount: bigint | undefined;
        }
      | undefined;
  }[];
};

// A transaction reaches this once per matched instruction it carries, and every
// one of those carries the same whole-transaction activities. Account rows are
// therefore written from the first instruction and skipped afterwards, keyed on
// (slot, txIndex); every other write is keyed so that repeats are identical.
async function applyTransaction(
  context: SvmOnSlotContext,
  slot: number,
  programName: string,
  instructionName: string,
  tx: LedgerTx,
): Promise<void> {
  // A failed transaction is rolled back, so its pre and post amounts agree and
  // it carries no balance change to record.
  if (!tx.success) return;

  const perMint = new Map<string, { sumDelta: bigint; accountsTouched: number }>();
  let changes = 0n;
  let newAccounts = 0n;
  let gaps = 0n;

  for (const activity of tx.accountActivities) {
    const token = activity.token;
    if (token === undefined) continue;

    // An amount is absent when the account did not hold the mint on that side
    // of the transaction — it was created, or closed.
    const preAmount = token.preAmount ?? 0n;
    const postAmount = token.postAmount ?? 0n;

    const flow = perMint.get(token.mint) ?? { sumDelta: 0n, accountsTouched: 0 };
    flow.sumDelta += postAmount - preAmount;
    flow.accountsTouched += 1;
    perMint.set(token.mint, flow);

    const previous = await context.TokenAccount.get(activity.address);
    if (previous && previous.lastSlot === slot && previous.lastTxIndex === tx.transactionIndex) {
      continue;
    }

    const isOpening = previous === undefined;
    const expectedPre = isOpening ? preAmount : previous.balance;
    const continuous = expectedPre === preAmount;

    context.BalanceChange.set({
      id: `${slot}:${tx.transactionIndex}:${activity.address}`,
      account: activity.address,
      mint: token.mint,
      owner: token.owner,
      decimals: token.decimals,
      slot,
      txIndex: tx.transactionIndex,
      txSig: tx.signature,
      preAmount,
      postAmount,
      delta: postAmount - preAmount,
      expectedPre,
      continuous,
      isOpening,
    });
    context.TokenAccount.set({
      id: activity.address,
      mint: token.mint,
      owner: token.owner,
      decimals: token.decimals,
      balance: postAmount,
      openingBalance: isOpening ? preAmount : previous.openingBalance,
      openingSlot: isOpening ? slot : previous.openingSlot,
      lastSlot: slot,
      lastTxIndex: tx.transactionIndex,
      changeCount: (previous?.changeCount ?? 0) + 1,
      gapCount: (previous?.gapCount ?? 0) + (continuous ? 0 : 1),
    });

    changes += 1n;
    if (isOpening) newAccounts += 1n;
    if (!continuous) gaps += 1n;
  }

  for (const [mint, flow] of perMint) {
    context.TxMintFlow.set({
      id: `${tx.signature}:${mint}`,
      txSig: tx.signature,
      mint,
      slot,
      sumDelta: flow.sumDelta,
      accountsTouched: flow.accountsTouched,
    });
  }
  context.TxTokenInstruction.set({
    id: `${tx.signature}:${programName}:${instructionName}`,
    txSig: tx.signature,
    slot,
    program: programName,
    instructionName,
    conserves: conservesAmount(programName, instructionName),
  });

  const stats = await context.LedgerStats.get(STATS_ID);
  context.LedgerStats.set({
    id: STATS_ID,
    lastSlot: Math.max(stats?.lastSlot ?? 0, slot),
    changes: (stats?.changes ?? 0n) + changes,
    accounts: (stats?.accounts ?? 0n) + newAccounts,
    gaps: (stats?.gaps ?? 0n) + gaps,
  });
}

const BALANCE_CHANGING = [
  "transfer",
  "mintTo",
  "burn",
  "closeAccount",
  "transferChecked",
  "mintToChecked",
  "burnChecked",
  "syncNative",
] as const;

const TOKEN_2022_ONLY = ["transferFeeExtension", "confidentialTransferExtension"] as const;

for (const name of BALANCE_CHANGING) {
  for (const program of ["SplToken", "Token2022"] as const) {
    indexer.onInstruction(
      { fields, program, instruction: name },
      async ({ instruction, context }) => {
        await applyTransaction(
          context,
          instruction.block.slot,
          instruction.programName,
          instruction.instructionName,
          instruction.transaction,
        );
      },
    );
  }
}

for (const name of TOKEN_2022_ONLY) {
  indexer.onInstruction(
    { fields, program: "Token2022", instruction: name },
    async ({ instruction, context }) => {
      await applyTransaction(
        context,
        instruction.block.slot,
        instruction.programName,
        instruction.instructionName,
        instruction.transaction,
      );
    },
  );
}
