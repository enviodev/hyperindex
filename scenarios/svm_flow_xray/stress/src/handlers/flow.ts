// Stress-test handler. Mirrors src/handlers/flow.ts but ALSO registers the two
// ultra-high-frequency programs (SplToken + System) so a matched instruction
// actually decodes -> dispatches -> writes entities. That entity-write path is
// the consumer-side memory cost we are characterizing (see Solana Issues P1).
//
// Each matched instruction writes one InstructionNode + one FlowTx + one
// TokenDelta per transaction.tokenBalances row, exactly as the live handler
// does, so peak memory reflects the real OOM driver: COUNT of matched
// instructions x per-tx token_balance fan-out.
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
import { writeFileSync } from "node:fs";

const STATS_ID = "global";

// The explicit-endBlock test path can loop at the window boundary without
// resolving process() (an SVM chunk-range off-by-one), so result.changes may
// never arrive. STRESS_COUNT_FILE lets the harness read a live running count of
// matched instructions / token-balance rows straight from the worker. Written
// from the worker thread (where handlers run), throttled to once per 10 ix.
const countFile = process.env.STRESS_COUNT_FILE;
let matchedIx = 0;
let tbRows = 0;
let lastFlush = 0;
function flushCounts(force = false): void {
  if (!countFile) return;
  if (!force && matchedIx - lastFlush < 10) return;
  lastFlush = matchedIx;
  try {
    writeFileSync(countFile, JSON.stringify({ matchedIx, tbRows }) + "\n");
  } catch {
    // best-effort; never let counting kill the handler under test
  }
}

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
    tbRows++;
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
    matchedIx++;
    flushCounts();
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
    matchedIx++;
    flushCounts();
  });
}

const bi = (x: unknown): bigint | undefined =>
  x === undefined || x === null ? undefined : BigInt(x as string | number | bigint);

type Args = Record<string, unknown>;
const splAmount: MapArgs = (d) => ({ argU64A: bi((d.args as Args).amount) });
const systemTransfer: MapArgs = (d) => ({ argU64A: bi((d.args as Args).lamports) });
const raydiumSwap: MapArgs = (d) => {
  const a = d.args as Args;
  return { argU64A: bi(a.amountIn), argU64B: bi(a.minAmountOut) };
};
const jupiterRoute: MapArgs = (d) => {
  const a = d.args as Args;
  return {
    argU64A: bi(a.inAmount),
    argU64B: bi(a.quotedOutAmount),
    argMintA: d.accounts.sourceMint,
    argMintB: d.accounts.destinationMint,
  };
};
const kaminoLiquidity: MapArgs = (d) => ({
  argU64A: bi((d.args as Args).liquidityAmount),
  argMintA: d.accounts.reserveLiquidityMint ?? d.accounts.borrowReserveLiquidityMint,
});
const kaminoWithdraw: MapArgs = (d) => ({
  argU64A: bi((d.args as Args).collateralAmount),
  argMintA: d.accounts.reserveLiquidityMint,
});
const driftPlacePerp: MapArgs = (d) => ({
  argMarketIndex: ((d.args as Args).params as { marketIndex?: number } | undefined)?.marketIndex,
});
const driftLiquidatePerp: MapArgs = (d) => {
  const a = d.args as Args;
  return { argMarketIndex: a.marketIndex as number | undefined, argU64A: bi(a.liquidatorMaxBaseAssetAmount) };
};
const driftLiquidateSpot: MapArgs = (d) => {
  const a = d.args as Args;
  return { argMarketIndex: a.liabilityMarketIndex as number | undefined, argU64A: bi(a.liquidatorMaxLiabilityTransfer) };
};
const driftSettlePnl: MapArgs = (d) => ({ argMarketIndex: (d.args as Args).marketIndex as number | undefined });

// DeFi protocols (always present in every stress variant).
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
register("Raydium", "swap", raydiumSwap);

// High-frequency programs. Only matched when the active config includes them
// (programSet "defi+hf"); registering a handler whose instruction isn't in the
// config is harmless. These are the OOM driver under test.
register("SplToken", "Transfer", splAmount);
register("SplToken", "TransferChecked", splAmount);
register("SplToken", "MintTo", splAmount);
register("SplToken", "Burn", splAmount);
register("System", "Transfer", systemTransfer);
