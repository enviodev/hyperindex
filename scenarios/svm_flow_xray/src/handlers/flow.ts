import {
  indexer,
  type InstructionNode,
  type TokenDelta,
  type FlowTx,
  type LiquidationEvent,
  type IndexerStats,
  type SvmInstruction,
  type SvmDecodedInstruction,
} from "envio";
import type {
  SplAmountArgs,
  SystemTransferArgs,
  RaydiumSwapArgs,
  JupiterRouteArgs,
  KaminoLiquidityArgs,
  KaminoWithdrawArgs,
  DriftPlacePerpArgs,
  DriftLiquidatePerpArgs,
  DriftLiquidateSpotArgs,
  DriftSettlePnlArgs,
} from "../types.js";

const STATS_ID = "global";

type EntityOps<T> = {
  get: (id: string) => Promise<T | undefined>;
  set: (entity: T) => void;
};
type FlowContext = {
  InstructionNode: EntityOps<InstructionNode>;
  TokenDelta: EntityOps<TokenDelta>;
  FlowTx: EntityOps<FlowTx>;
  LiquidationEvent: EntityOps<LiquidationEvent>;
  IndexerStats: EntityOps<IndexerStats>;
};

type NodeArgs = {
  argU64A?: bigint;
  argU64B?: bigint;
  argMintA?: string;
  argMintB?: string;
  argMarketIndex?: number;
};
type MapArgs = (decoded: SvmDecodedInstruction) => NodeArgs;

// The generated `onInstruction` keys program/instruction off codegen literal
// unions; we drive registration from plain strings (kept in sync with config.yaml
// + idls/NAMES.md), so widen the signature once here.
const onIx = indexer.onInstruction as unknown as (
  options: { program: string; instruction: string },
  handler: (a: { instruction: SvmInstruction; context: FlowContext }) => Promise<void>,
) => void;

const addrPath = (a: readonly number[]): string => a.join(".");
const parentOf = (a: readonly number[]): string | undefined =>
  a.length <= 1 ? undefined : a.slice(0, -1).join(".");

function writeTokenDeltas(instruction: SvmInstruction, context: FlowContext, txSig: string): void {
  for (const b of instruction.transaction?.tokenBalances ?? []) {
    if (!b.account) continue;
    const pre = BigInt(b.preAmount ?? "0");
    const post = BigInt(b.postAmount ?? "0");
    context.TokenDelta.set({
      id: `${txSig}:${b.account}`,
      txSig,
      slot: instruction.slot,
      account: b.account,
      mint: b.mint ?? "",
      owner: b.owner,
      preAmount: pre,
      postAmount: post,
      delta: post - pre,
    });
  }
}

function writeFlowTx(instruction: SvmInstruction, context: FlowContext, txSig: string): void {
  context.FlowTx.set({
    id: txSig,
    slot: instruction.slot,
    feePayer: instruction.transaction?.feePayer,
    success: instruction.transaction?.success,
    fee: instruction.transaction?.fee,
    computeUnits: instruction.transaction?.computeUnitsConsumed,
  });
}

async function bumpStats(instruction: SvmInstruction, context: FlowContext): Promise<void> {
  const prev = await context.IndexerStats.get(STATS_ID);
  context.IndexerStats.set({
    id: STATS_ID,
    lastSlot: Math.max(prev?.lastSlot ?? 0, instruction.slot),
    totalInstructions: (prev?.totalInstructions ?? 0n) + 1n,
  });
}

function writeNode(
  instruction: SvmInstruction,
  context: FlowContext,
  program: string,
  instructionName: string,
  extra: NodeArgs,
): void {
  const txSig = instruction.transaction?.signatures[0];
  if (!txSig) return;
  const addr = instruction.instructionAddress;
  const path = addrPath(addr);
  const decoded = instruction.decoded;
  context.InstructionNode.set({
    id: `${txSig}:${path}`,
    txSig,
    slot: instruction.slot,
    addrPath: path,
    depth: Math.max(0, addr.length - 1),
    parentPath: parentOf(addr),
    program,
    programId: instruction.programId,
    // A handler only fires for its instruction's discriminator, so the
    // registered name is correct even when borsh decode fails (e.g. a Jupiter
    // routePlan variant newer than the bundled IDL).
    ixName: decoded?.name ?? instructionName,
    isInner: instruction.isInner,
    feePayer: instruction.transaction?.feePayer,
    success: instruction.transaction?.success,
    fee: instruction.transaction?.fee,
    computeUnits: instruction.transaction?.computeUnitsConsumed,
    argU64A: extra.argU64A,
    argU64B: extra.argU64B,
    argMintA: extra.argMintA,
    argMintB: extra.argMintB,
    argMarketIndex: extra.argMarketIndex,
  });
  writeFlowTx(instruction, context, txSig);
  writeTokenDeltas(instruction, context, txSig);
}

function register(program: string, instructionName: string, mapArgs?: MapArgs): void {
  onIx({ program, instruction: instructionName }, async ({ instruction, context }) => {
    const decoded = instruction.decoded;
    const extra = decoded && mapArgs ? mapArgs(decoded) : {};
    writeNode(instruction, context, program, instructionName, extra);
    await bumpStats(instruction, context);
  });
}

function registerLiquidation(program: string, instructionName: string, mapArgs: MapArgs): void {
  onIx({ program, instruction: instructionName }, async ({ instruction, context }) => {
    const decoded = instruction.decoded;
    const extra = decoded ? mapArgs(decoded) : {};
    writeNode(instruction, context, program, instructionName, extra);
    const txSig = instruction.transaction?.signatures[0];
    if (txSig) {
      context.LiquidationEvent.set({
        id: `${txSig}:${addrPath(instruction.instructionAddress)}`,
        txSig,
        slot: instruction.slot,
        ixName: decoded?.name ?? instructionName,
        marketIndex: extra.argMarketIndex,
        liabilityAmount: extra.argU64A,
      });
    }
    await bumpStats(instruction, context);
  });
}

// IDL-decoded programs surface decoded.args loosely (codegen types them `{}`),
// so every field read is treated as possibly-absent: BigInt(undefined) would
// throw and kill the handler for an entire protocol.
const bi = (x: unknown): bigint | undefined =>
  x === undefined || x === null ? undefined : BigInt(x as string | number | bigint);

const splAmount: MapArgs = (d) => ({ argU64A: bi((d.args as Partial<SplAmountArgs>).amount) });
const systemTransfer: MapArgs = (d) => ({ argU64A: bi((d.args as Partial<SystemTransferArgs>).lamports) });
const raydiumSwap: MapArgs = (d) => {
  const a = d.args as Partial<RaydiumSwapArgs>;
  return { argU64A: bi(a.amountIn), argU64B: bi(a.minAmountOut) };
};
const jupiterRoute: MapArgs = (d) => {
  const a = d.args as Partial<JupiterRouteArgs>;
  return {
    argU64A: bi(a.inAmount),
    argU64B: bi(a.quotedOutAmount),
    argMintA: d.accounts.sourceMint,
    argMintB: d.accounts.destinationMint,
  };
};
const kaminoLiquidity: MapArgs = (d) => ({
  argU64A: bi((d.args as Partial<KaminoLiquidityArgs>).liquidityAmount),
  argMintA: d.accounts.reserveLiquidityMint ?? d.accounts.borrowReserveLiquidityMint,
});
const kaminoWithdraw: MapArgs = (d) => ({
  argU64A: bi((d.args as Partial<KaminoWithdrawArgs>).collateralAmount),
  argMintA: d.accounts.reserveLiquidityMint,
});
const driftPlacePerp: MapArgs = (d) => ({
  argMarketIndex: (d.args as DriftPlacePerpArgs).params?.marketIndex,
});
const driftLiquidatePerp: MapArgs = (d) => {
  const a = d.args as Partial<DriftLiquidatePerpArgs>;
  return { argMarketIndex: a.marketIndex, argU64A: bi(a.liquidatorMaxBaseAssetAmount) };
};
const driftLiquidateSpot: MapArgs = (d) => {
  const a = d.args as Partial<DriftLiquidateSpotArgs>;
  return { argMarketIndex: a.liabilityMarketIndex, argU64A: bi(a.liquidatorMaxLiabilityTransfer) };
};
const driftSettlePnl: MapArgs = (d) => ({ argMarketIndex: (d.args as Partial<DriftSettlePnlArgs>).marketIndex });

register("Jupiter", "route", jupiterRoute);
register("Jupiter", "sharedAccountsRoute", jupiterRoute);

register("Kamino", "depositReserveLiquidityAndObligationCollateral", kaminoLiquidity);
register("Kamino", "borrowObligationLiquidity", kaminoLiquidity);
register("Kamino", "repayObligationLiquidity", kaminoLiquidity);
register("Kamino", "withdrawObligationCollateralAndRedeemReserveCollateral", kaminoWithdraw);

register("Drift", "placePerpOrder", driftPlacePerp);
register("Drift", "fillPerpOrder");
registerLiquidation("Drift", "liquidatePerp", driftLiquidatePerp);
registerLiquidation("Drift", "liquidateSpot", driftLiquidateSpot);
register("Drift", "settlePnl", driftSettlePnl);

// SplToken + System are not matched (volume); see config.yaml. Their mapArgs
// (splAmount / systemTransfer) are kept for a future tight-window deep dive.
register("Raydium", "swap", raydiumSwap);

// Orca + Meteora swap: discriminator-filtered (not program-wide), so the
// CPI tree gets the protocol nodes Jupiter routes through.
register("Orca", "swap");
register("Meteora", "swap");
