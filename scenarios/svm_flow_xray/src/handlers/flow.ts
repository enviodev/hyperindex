import {
  indexer,
  type InstructionNode,
  type TokenDelta,
  type FlowTx,
  type LiquidationEvent,
  type IndexerStats,
  type SvmInstructionEvent,
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
  handler: (a: { event: SvmInstructionEvent; context: FlowContext }) => Promise<void>,
) => void;

const addrPath = (a: readonly number[]): string => a.join(".");
const parentOf = (a: readonly number[]): string | undefined =>
  a.length <= 1 ? undefined : a.slice(0, -1).join(".");

function writeTokenDeltas(event: SvmInstructionEvent, context: FlowContext, txSig: string): void {
  for (const b of event.transaction?.tokenBalances ?? []) {
    if (!b.account) continue;
    const pre = BigInt(b.preAmount ?? "0");
    const post = BigInt(b.postAmount ?? "0");
    context.TokenDelta.set({
      id: `${txSig}:${b.account}`,
      txSig,
      slot: event.slot,
      account: b.account,
      mint: b.mint ?? "",
      owner: b.owner,
      preAmount: pre,
      postAmount: post,
      delta: post - pre,
    });
  }
}

function writeFlowTx(event: SvmInstructionEvent, context: FlowContext, txSig: string): void {
  context.FlowTx.set({
    id: txSig,
    slot: event.slot,
    feePayer: event.transaction?.feePayer,
    success: event.transaction?.success,
    fee: event.transaction?.fee,
    computeUnits: event.transaction?.computeUnitsConsumed,
  });
}

async function bumpStats(event: SvmInstructionEvent, context: FlowContext): Promise<void> {
  const prev = await context.IndexerStats.get(STATS_ID);
  context.IndexerStats.set({
    id: STATS_ID,
    lastSlot: Math.max(prev?.lastSlot ?? 0, event.slot),
    totalInstructions: (prev?.totalInstructions ?? 0n) + 1n,
  });
}

function writeNode(
  event: SvmInstructionEvent,
  context: FlowContext,
  program: string,
  instruction: string,
  extra: NodeArgs,
): void {
  const txSig = event.transaction?.signatures[0];
  if (!txSig) return;
  const addr = event.instruction.instructionAddress;
  const path = addrPath(addr);
  const decoded = event.instruction.decoded;
  context.InstructionNode.set({
    id: `${txSig}:${path}`,
    txSig,
    slot: event.slot,
    addrPath: path,
    depth: Math.max(0, addr.length - 1),
    parentPath: parentOf(addr),
    program,
    programId: event.instruction.programId,
    // A handler only fires for its instruction's discriminator, so the
    // registered name is correct even when borsh decode fails (e.g. a Jupiter
    // routePlan variant newer than the bundled IDL).
    ixName: decoded?.name ?? instruction,
    isInner: event.instruction.isInner,
    feePayer: event.transaction?.feePayer,
    success: event.transaction?.success,
    fee: event.transaction?.fee,
    computeUnits: event.transaction?.computeUnitsConsumed,
    argU64A: extra.argU64A,
    argU64B: extra.argU64B,
    argMintA: extra.argMintA,
    argMintB: extra.argMintB,
    argMarketIndex: extra.argMarketIndex,
  });
  writeFlowTx(event, context, txSig);
  writeTokenDeltas(event, context, txSig);
}

function register(program: string, instruction: string, mapArgs?: MapArgs): void {
  onIx({ program, instruction }, async ({ event, context }) => {
    const decoded = event.instruction.decoded;
    const extra = decoded && mapArgs ? mapArgs(decoded) : {};
    writeNode(event, context, program, instruction, extra);
    await bumpStats(event, context);
  });
}

function registerLiquidation(program: string, instruction: string, mapArgs: MapArgs): void {
  onIx({ program, instruction }, async ({ event, context }) => {
    const decoded = event.instruction.decoded;
    const extra = decoded ? mapArgs(decoded) : {};
    writeNode(event, context, program, instruction, extra);
    const txSig = event.transaction?.signatures[0];
    if (txSig) {
      context.LiquidationEvent.set({
        id: `${txSig}:${addrPath(event.instruction.instructionAddress)}`,
        txSig,
        slot: event.slot,
        ixName: decoded?.name ?? instruction,
        marketIndex: extra.argMarketIndex,
        liabilityAmount: extra.argU64A,
      });
    }
    await bumpStats(event, context);
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
