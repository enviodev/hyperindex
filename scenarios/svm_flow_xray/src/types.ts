// Local narrowing for `instruction.decoded.args` (typed `unknown` upstream).
// Borsh renders >=64-bit ints as decimal strings; BigInt(...) them for arithmetic.

export interface SplAmountArgs {
  amount: string;
}

export interface SystemTransferArgs {
  lamports: string;
}

export interface RaydiumSwapArgs {
  amountIn: string;
  minAmountOut: string;
}

export interface JupiterRouteArgs {
  inAmount: string;
  quotedOutAmount: string;
  slippageBps: number;
  platformFeeBps: number;
}

export interface KaminoLiquidityArgs {
  liquidityAmount: string;
}

export interface KaminoWithdrawArgs {
  collateralAmount: string;
}

export interface DriftPlacePerpArgs {
  params?: { marketIndex?: number };
}

export interface DriftLiquidatePerpArgs {
  marketIndex: number;
  liquidatorMaxBaseAssetAmount: string;
}

export interface DriftLiquidateSpotArgs {
  assetMarketIndex: number;
  liabilityMarketIndex: number;
  liquidatorMaxLiabilityTransfer: string;
}

export interface DriftSettlePnlArgs {
  marketIndex: number;
}
