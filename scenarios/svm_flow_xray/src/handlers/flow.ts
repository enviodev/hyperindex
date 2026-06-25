import { indexer, type SvmOnSlotContext, type SvmTokenBalance } from "envio";

const STATS_ID = "global";

const addrPath = (a: readonly number[]): string => a.join(".");
const parentOf = (a: readonly number[]): string | undefined =>
  a.length <= 1 ? undefined : a.slice(0, -1).join(".");

// Decoded args are best-effort (borsh decode can fail on IDL drift), so every
// numeric read is treated as possibly-absent: BigInt(undefined) would throw and
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
  tokenBalances: readonly SvmTokenBalance[];
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
      if (!b.account) continue;
      const pre = BigInt(b.preAmount ?? "0");
      const post = BigInt(b.postAmount ?? "0");
      context.TokenDelta.set({
        id: `${txSig}:${b.account}`,
        txSig,
        slot: e.slot,
        account: b.account,
        mint: b.mint ?? "",
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

indexer.onInstruction({ program: "Jupiter", instruction: "route" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  const args = instruction.params?.args;
  await record(context, {
    program: "Jupiter",
    ixName: instruction.params?.name ?? "route",
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.instructionAddress,
    txSig: tx.signatures[0],
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tx.tokenBalances ?? [],
    argU64A: bi(args?.inAmount),
    argU64B: bi(args?.quotedOutAmount),
    argMintB: instruction.params?.accounts.destinationMint,
  });
});

indexer.onInstruction({ program: "Jupiter", instruction: "sharedAccountsRoute" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  const args = instruction.params?.args;
  await record(context, {
    program: "Jupiter",
    ixName: instruction.params?.name ?? "sharedAccountsRoute",
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.instructionAddress,
    txSig: tx.signatures[0],
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tx.tokenBalances ?? [],
    argU64A: bi(args?.inAmount),
    argU64B: bi(args?.quotedOutAmount),
    argMintA: instruction.params?.accounts.sourceMint,
    argMintB: instruction.params?.accounts.destinationMint,
  });
});

indexer.onInstruction({ program: "Kamino", instruction: "depositReserveLiquidityAndObligationCollateral" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  await record(context, {
    program: "Kamino",
    ixName: instruction.params?.name ?? "depositReserveLiquidityAndObligationCollateral",
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.instructionAddress,
    txSig: tx.signatures[0],
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tx.tokenBalances ?? [],
    argU64A: bi(instruction.params?.args.liquidityAmount),
    argMintA: instruction.params?.accounts.reserveLiquidityMint,
  });
});

indexer.onInstruction({ program: "Kamino", instruction: "borrowObligationLiquidity" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  await record(context, {
    program: "Kamino",
    ixName: instruction.params?.name ?? "borrowObligationLiquidity",
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.instructionAddress,
    txSig: tx.signatures[0],
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tx.tokenBalances ?? [],
    argU64A: bi(instruction.params?.args.liquidityAmount),
    argMintA: instruction.params?.accounts.borrowReserveLiquidityMint,
  });
});

indexer.onInstruction({ program: "Kamino", instruction: "repayObligationLiquidity" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  await record(context, {
    program: "Kamino",
    ixName: instruction.params?.name ?? "repayObligationLiquidity",
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.instructionAddress,
    txSig: tx.signatures[0],
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tx.tokenBalances ?? [],
    argU64A: bi(instruction.params?.args.liquidityAmount),
    argMintA: instruction.params?.accounts.reserveLiquidityMint,
  });
});

indexer.onInstruction({ program: "Kamino", instruction: "withdrawObligationCollateralAndRedeemReserveCollateral" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  await record(context, {
    program: "Kamino",
    ixName: instruction.params?.name ?? "withdrawObligationCollateralAndRedeemReserveCollateral",
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.instructionAddress,
    txSig: tx.signatures[0],
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tx.tokenBalances ?? [],
    argU64A: bi(instruction.params?.args.collateralAmount),
    argMintA: instruction.params?.accounts.reserveLiquidityMint,
  });
});

indexer.onInstruction({ program: "Drift", instruction: "placePerpOrder" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  await record(context, {
    program: "Drift",
    ixName: instruction.params?.name ?? "placePerpOrder",
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.instructionAddress,
    txSig: tx.signatures[0],
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tx.tokenBalances ?? [],
    argMarketIndex: instruction.params?.args.params?.marketIndex,
  });
});

indexer.onInstruction({ program: "Drift", instruction: "fillPerpOrder" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  await record(context, {
    program: "Drift",
    ixName: instruction.params?.name ?? "fillPerpOrder",
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.instructionAddress,
    txSig: tx.signatures[0],
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tx.tokenBalances ?? [],
  });
});

indexer.onInstruction({ program: "Drift", instruction: "liquidatePerp" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  const args = instruction.params?.args;
  const marketIndex = args?.marketIndex;
  const liabilityAmount = bi(args?.liquidatorMaxBaseAssetAmount);
  await record(context, {
    program: "Drift",
    ixName: instruction.params?.name ?? "liquidatePerp",
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.instructionAddress,
    txSig: tx.signatures[0],
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tx.tokenBalances ?? [],
    argMarketIndex: marketIndex,
    argU64A: liabilityAmount,
    liquidation: { marketIndex, liabilityAmount },
  });
});

indexer.onInstruction({ program: "Drift", instruction: "liquidateSpot" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  const args = instruction.params?.args;
  const marketIndex = args?.liabilityMarketIndex;
  const liabilityAmount = bi(args?.liquidatorMaxLiabilityTransfer);
  await record(context, {
    program: "Drift",
    ixName: instruction.params?.name ?? "liquidateSpot",
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.instructionAddress,
    txSig: tx.signatures[0],
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tx.tokenBalances ?? [],
    argMarketIndex: marketIndex,
    argU64A: liabilityAmount,
    liquidation: { marketIndex, liabilityAmount },
  });
});

indexer.onInstruction({ program: "Drift", instruction: "settlePnl" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  await record(context, {
    program: "Drift",
    ixName: instruction.params?.name ?? "settlePnl",
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.instructionAddress,
    txSig: tx.signatures[0],
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tx.tokenBalances ?? [],
    argMarketIndex: instruction.params?.args.marketIndex,
  });
});

// SplToken + System are not matched (volume); see config.yaml. Per-tx token
// movement still arrives via transaction.tokenBalances on the DeFi events.
indexer.onInstruction({ program: "Raydium", instruction: "swap" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  const args = instruction.params?.args;
  await record(context, {
    program: "Raydium",
    ixName: instruction.params?.name ?? "swap",
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.instructionAddress,
    txSig: tx.signatures[0],
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tx.tokenBalances ?? [],
    argU64A: bi(args?.amountIn),
    argU64B: bi(args?.minAmountOut),
  });
});

// Orca + Meteora swap: discriminator-filtered (not program-wide), so the CPI
// tree gets the protocol nodes Jupiter routes through.
indexer.onInstruction({ program: "Orca", instruction: "swap" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  await record(context, {
    program: "Orca",
    ixName: instruction.params?.name ?? "swap",
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.instructionAddress,
    txSig: tx.signatures[0],
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tx.tokenBalances ?? [],
  });
});

indexer.onInstruction({ program: "Meteora", instruction: "swap" }, async ({ instruction, context }) => {
  const tx = instruction.transaction;
  await record(context, {
    program: "Meteora",
    ixName: instruction.params?.name ?? "swap",
    programId: instruction.programId,
    isInner: instruction.isInner,
    slot: instruction.block.slot,
    addr: instruction.instructionAddress,
    txSig: tx.signatures[0],
    feePayer: tx.feePayer,
    success: tx.success,
    fee: tx.fee,
    computeUnits: tx.computeUnitsConsumed,
    tokenBalances: tx.tokenBalances ?? [],
  });
});
