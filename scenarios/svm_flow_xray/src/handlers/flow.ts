import { indexer, type SvmOnSlotContext } from "envio";

const STATS_ID = "global";

const addrPath = (a: readonly number[]): string => a.join(".");
const parentOf = (a: readonly number[]): string | undefined =>
  a.length <= 1 ? undefined : a.slice(0, -1).join(".");

// An instruction the IDL can't decode never reaches a handler, but an arg the
// IDL declares optional still can be absent: BigInt(undefined) would throw and
// kill the handler for an entire protocol.
const bi = (x: unknown): bigint | undefined =>
  x === undefined || x === null ? undefined : BigInt(x as string | number | bigint);

// Plain write-shape passed to `record`. Carries only already-extracted values,
// so the per-instruction transaction reads (and their `FieldNotSelected` compile
// guard) stay at the inline `onInstruction` call sites where the type is exact.
type FlowEvent = {
  program: string;
  ixName: string;
  programId: string;
  isInner: boolean;
  slot: number;
  addr: readonly number[];
  txSig: string | undefined;
  feePayer: string | undefined;
  success: boolean | undefined;
  fee: bigint | undefined;
  computeUnits: bigint | undefined;
  tokenBalances: readonly {
    account: string;
    mint: string;
    owner: string | undefined;
    preAmount: bigint | undefined;
    postAmount: bigint | undefined;
  }[];
  argU64A?: bigint;
  argU64B?: bigint;
  argMintA?: string;
  argMintB?: string;
  argMarketIndex?: number;
  liquidation?: { marketIndex: number | undefined; liabilityAmount: bigint | undefined };
};

async function record(context: SvmOnSlotContext, e: FlowEvent): Promise<void> {
  if (e.txSig) {
    const txSig = e.txSig;
    const path = addrPath(e.addr);
    context.InstructionNode.set({
      id: `${txSig}:${path}`,
      txSig,
      slot: e.slot,
      addrPath: path,
      depth: Math.max(0, e.addr.length - 1),
      parentPath: parentOf(e.addr),
      program: e.program,
      programId: e.programId,
      ixName: e.ixName,
      isInner: e.isInner,
      feePayer: e.feePayer,
      success: e.success,
      fee: e.fee,
      computeUnits: e.computeUnits,
      argU64A: e.argU64A,
      argU64B: e.argU64B,
      argMintA: e.argMintA,
      argMintB: e.argMintB,
      argMarketIndex: e.argMarketIndex,
    });
    context.FlowTx.set({
      id: txSig,
      slot: e.slot,
      feePayer: e.feePayer,
      success: e.success,
      fee: e.fee,
      computeUnits: e.computeUnits,
    });
    for (const b of e.tokenBalances) {
      const pre = b.preAmount ?? 0n;
      const post = b.postAmount ?? 0n;
      context.TokenDelta.set({
        id: `${txSig}:${b.account}`,
        txSig,
        slot: e.slot,
        account: b.account,
        mint: b.mint,
        owner: b.owner,
        preAmount: pre,
        postAmount: post,
        delta: post - pre,
      });
    }
    if (e.liquidation) {
      context.LiquidationEvent.set({
        id: `${txSig}:${path}`,
        txSig,
        slot: e.slot,
        ixName: e.ixName,
        marketIndex: e.liquidation.marketIndex,
        liabilityAmount: e.liquidation.liabilityAmount,
      });
    }
  }
  // Stats bump for every matched instruction, even one whose transaction
  // carried no signature.
  const prev = await context.IndexerStats.get(STATS_ID);
  context.IndexerStats.set({
    id: STATS_ID,
    lastSlot: Math.max(prev?.lastSlot ?? 0, e.slot),
    totalInstructions: (prev?.totalInstructions ?? 0n) + 1n,
  });
}


const flowFields = {
  instruction: ["args", "accounts", "programId", "path", "isInner"],
  transaction: ["signature", "feePayer", "success", "fee", "computeUnitsConsumed"],
  accountActivity: ["address", "token.mint", "token.owner", "token.preAmount", "token.postAmount"],
} as const;

// Orca and Meteora `swap` are matched on discriminator alone, so they declare
// no args to select.
const bareFlowFields = {
  ...flowFields,
  instruction: ["accounts", "programId", "path", "isInner"],
} as const;

const tokenBalancesOf = (tx: { accountActivities: readonly { address: string; token: { mint: string; owner: string; preAmount: bigint | undefined; postAmount: bigint | undefined } | undefined }[] }) =>
  tx.accountActivities.flatMap(a => {
    const t = a.token;
    if (!t) return [];
    return [{ account: a.address, mint: t.mint, owner: t.owner, preAmount: t.preAmount, postAmount: t.postAmount }];
  });

indexer.onInstruction({ fields: flowFields, program: "Jupiter", instruction: "route" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  const args = instruction.args;
  await record(context, {
    program: "Jupiter",
    ixName: instruction.instructionName,
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.path,
    txSig: tx.signature,
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tokenBalancesOf(tx),
    argU64A: bi(args?.inAmount),
    argU64B: bi(args?.quotedOutAmount),
    argMintB: instruction.accounts.destinationMint.address,
  });
});

indexer.onInstruction({ fields: flowFields, program: "Jupiter", instruction: "sharedAccountsRoute" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  const args = instruction.args;
  await record(context, {
    program: "Jupiter",
    ixName: instruction.instructionName,
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.path,
    txSig: tx.signature,
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tokenBalancesOf(tx),
    argU64A: bi(args?.inAmount),
    argU64B: bi(args?.quotedOutAmount),
    argMintA: instruction.accounts.sourceMint.address,
    argMintB: instruction.accounts.destinationMint.address,
  });
});

indexer.onInstruction({ fields: flowFields, program: "Kamino", instruction: "depositReserveLiquidityAndObligationCollateral" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  await record(context, {
    program: "Kamino",
    ixName: instruction.instructionName,
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.path,
    txSig: tx.signature,
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tokenBalancesOf(tx),
    argU64A: bi(instruction.args.liquidityAmount),
    argMintA: instruction.accounts.reserveLiquidityMint.address,
  });
});

indexer.onInstruction({ fields: flowFields, program: "Kamino", instruction: "borrowObligationLiquidity" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  await record(context, {
    program: "Kamino",
    ixName: instruction.instructionName,
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.path,
    txSig: tx.signature,
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tokenBalancesOf(tx),
    argU64A: bi(instruction.args.liquidityAmount),
    argMintA: instruction.accounts.borrowReserveLiquidityMint.address,
  });
});

indexer.onInstruction({ fields: flowFields, program: "Kamino", instruction: "repayObligationLiquidity" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  await record(context, {
    program: "Kamino",
    ixName: instruction.instructionName,
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.path,
    txSig: tx.signature,
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tokenBalancesOf(tx),
    argU64A: bi(instruction.args.liquidityAmount),
    argMintA: instruction.accounts.reserveLiquidityMint.address,
  });
});

indexer.onInstruction({ fields: flowFields, program: "Kamino", instruction: "withdrawObligationCollateralAndRedeemReserveCollateral" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  await record(context, {
    program: "Kamino",
    ixName: instruction.instructionName,
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.path,
    txSig: tx.signature,
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tokenBalancesOf(tx),
    argU64A: bi(instruction.args.collateralAmount),
    argMintA: instruction.accounts.reserveLiquidityMint.address,
  });
});

indexer.onInstruction({ fields: flowFields, program: "Drift", instruction: "placePerpOrder" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  await record(context, {
    program: "Drift",
    ixName: instruction.instructionName,
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.path,
    txSig: tx.signature,
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tokenBalancesOf(tx),
    argMarketIndex: instruction.args?.params?.marketIndex,
  });
});

indexer.onInstruction({ fields: flowFields, program: "Drift", instruction: "fillPerpOrder" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  await record(context, {
    program: "Drift",
    ixName: instruction.instructionName,
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.path,
    txSig: tx.signature,
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tokenBalancesOf(tx),
  });
});

indexer.onInstruction({ fields: flowFields, program: "Drift", instruction: "liquidatePerp" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  const args = instruction.args;
  const marketIndex = args?.marketIndex;
  const liabilityAmount = bi(args?.liquidatorMaxBaseAssetAmount);
  await record(context, {
    program: "Drift",
    ixName: instruction.instructionName,
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.path,
    txSig: tx.signature,
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tokenBalancesOf(tx),
    argMarketIndex: marketIndex,
    argU64A: liabilityAmount,
    liquidation: { marketIndex, liabilityAmount },
  });
});

indexer.onInstruction({ fields: flowFields, program: "Drift", instruction: "liquidateSpot" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  const args = instruction.args;
  const marketIndex = args?.liabilityMarketIndex;
  const liabilityAmount = bi(args?.liquidatorMaxLiabilityTransfer);
  await record(context, {
    program: "Drift",
    ixName: instruction.instructionName,
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.path,
    txSig: tx.signature,
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tokenBalancesOf(tx),
    argMarketIndex: marketIndex,
    argU64A: liabilityAmount,
    liquidation: { marketIndex, liabilityAmount },
  });
});

indexer.onInstruction({ fields: flowFields, program: "Drift", instruction: "settlePnl" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  await record(context, {
    program: "Drift",
    ixName: instruction.instructionName,
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.path,
    txSig: tx.signature,
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tokenBalancesOf(tx),
    argMarketIndex: instruction.args.marketIndex,
  });
});

// SplToken + System are not matched (volume); see config.yaml. Per-tx token
// movement still arrives via transaction.accountActivities on the DeFi events.
indexer.onInstruction({ fields: flowFields, program: "Raydium", instruction: "swap" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  const args = instruction.args;
  await record(context, {
    program: "Raydium",
    ixName: instruction.instructionName,
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.path,
    txSig: tx.signature,
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tokenBalancesOf(tx),
    argU64A: bi(args?.amountIn),
    argU64B: bi(args?.minAmountOut),
  });
});

// Orca + Meteora swap: discriminator-filtered (not program-wide), so the CPI
// tree gets the protocol nodes Jupiter routes through.
indexer.onInstruction({ fields: bareFlowFields, program: "Orca", instruction: "swap" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  await record(context, {
    program: "Orca",
    ixName: instruction.instructionName,
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.path,
    txSig: tx.signature,
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tokenBalancesOf(tx),
  });
});

indexer.onInstruction({ fields: bareFlowFields, program: "Meteora", instruction: "swap" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  await record(context, {
    program: "Meteora",
    ixName: instruction.instructionName,
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.path,
    txSig: tx.signature,
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tokenBalancesOf(tx),
  });
});
