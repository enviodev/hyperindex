# IDL Instruction Name Manifest (Stream B)

Generated 2026-05-28 by Stream B. Source of truth for `config.yaml` instruction
names. Codegen errors on any name mismatch, so use these EXACT strings.

## IDL format note (all three)

All three fetched IDLs are **legacy Anchor format (pre-0.30)**:
- Top-level keys: `name`, `version`, `instructions`, `accounts`, `types`, `events`, `errors`.
- NO top-level `address` field, NO `metadata.spec`, NO per-instruction
  `discriminator` byte arrays. Anchor derives each instruction's 8-byte
  discriminator from `sha256("global:<snake_case_name>")[..8]` at decode time.
- This is the same shape HyperIndex's `idl:` program-level path already consumes
  (it computes the discriminator itself). No conversion needed.

| Program | File | Size | Version | Format |
|---|---|---|---|---|
| Jupiter v6 | `jupiter.json` | 77 KB | 0.1.0 | legacy Anchor |
| Drift v2 | `drift.json` | 439 KB | 2.162.0 | legacy Anchor |
| Kamino Lend (klend) | `kamino.json` | 173 KB | 1.13.0 (`kamino_lending`) | legacy Anchor |

Sources:
- jupiter.json: https://raw.githubusercontent.com/jup-ag/jupiter-cpi/main/idl.json
- drift.json:   https://raw.githubusercontent.com/drift-labs/protocol-v2/master/sdk/src/idl/drift.json
- kamino.json:  https://raw.githubusercontent.com/Kamino-Finance/klend-sdk/master/src/idl/klend.json

NOTE: none of these IDLs embed the on-chain program_id (legacy IDLs omit
`address`). Program IDs in `config.yaml` come from the spec, not the IDL. The
program_id <-> IDL pairing is correct per canonical repo provenance above.

---

## Jupiter (`JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4`)

Both intended instructions CONFIRMED present (exact names match):

### `route`  ✅
- accounts (ordered): `tokenProgram, userTransferAuthority, userSourceTokenAccount, userDestinationTokenAccount, destinationTokenAccount, destinationMint, platformFeeAccount, eventAuthority, program`
- args: `routePlan: Vec<RoutePlanStep>`, `inAmount: u64`, `quotedOutAmount: u64`, `slippageBps: u16`, `platformFeeBps: u8`

### `sharedAccountsRoute`  ✅
- accounts (ordered): `tokenProgram, programAuthority, userTransferAuthority, sourceTokenAccount, programSourceTokenAccount, programDestinationTokenAccount, destinationTokenAccount, sourceMint, destinationMint, platformFeeAccount, token2022Program, eventAuthority, program`
- args: `id: u8`, `routePlan: Vec<RoutePlanStep>`, `inAmount: u64`, `quotedOutAmount: u64`, `slippageBps: u16`, `platformFeeBps: u8`

Other notable route variants in the IDL (not configured, FYI):
`routeWithTokenLedger`, `sharedAccountsRouteWithTokenLedger`, `sharedAccountsExactOutRoute`.

---

## Drift (`dRiftyHA39MWEi3m9aunc5MzRF1JYuBsbn6VPcn33UH`)

All 5 intended instructions CONFIRMED present (exact names match):

### `placePerpOrder`  ✅
- accounts: `state, user, authority`
- args: `params: OrderParams`

### `fillPerpOrder`  ✅
- accounts: `state, authority, filler, fillerStats, user, userStats`
  (plus trailing `remainingAccounts` for maker/oracle/markets, variable)
- args: `orderId: Option<u32>`, `makerOrderId: Option<u32>`

### `liquidatePerp`  ✅  (config: also set `log_fields: true`)
- accounts: `state, authority, liquidator, liquidatorStats, user, userStats`
- args: `marketIndex: u16`, `liquidatorMaxBaseAssetAmount: u64`, `limitPrice: Option<u64>`

### `liquidateSpot`  ✅  (config: also set `log_fields: true`)
- accounts: `state, authority, liquidator, liquidatorStats, user, userStats`
- args: `assetMarketIndex: u16`, `liabilityMarketIndex: u16`, `liquidatorMaxLiabilityTransfer: u128`, `limitPrice: Option<u64>`

### `settlePnl`  ✅
- accounts: `state, user, authority, spotMarketVault`
- args: `marketIndex: u16`

Related liquidation variants present (not configured, FYI):
`liquidatePerpWithFill`, `liquidateBorrowForPerpPnl`, `liquidatePerpPnlForDeposit`,
`liquidateSpotWithSwapBegin`, `liquidateSpotWithSwapEnd`.

---

## Kamino Lend / klend (`KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD`)

3 of 4 intended instructions match; **WITHDRAW name differs - SEE FLAG**.

### `depositReserveLiquidityAndObligationCollateral`  ✅
- accounts: `owner, obligation, lendingMarket, lendingMarketAuthority, reserve, reserveLiquidityMint, reserveLiquiditySupply, reserveCollateralMint, reserveDestinationDepositCollateral, userSourceLiquidity, placeholderUserDestinationCollateral, collateralTokenProgram, liquidityTokenProgram, instructionSysvarAccount`
- args: `liquidityAmount: u64`

### `borrowObligationLiquidity`  ✅
- accounts: `owner, obligation, lendingMarket, lendingMarketAuthority, borrowReserve, borrowReserveLiquidityMint, reserveSourceLiquidity, borrowReserveLiquidityFeeReceiver, userDestinationLiquidity, referrerTokenState, tokenProgram, instructionSysvarAccount`
- args: `liquidityAmount: u64`

### `repayObligationLiquidity`  ✅
- accounts: `owner, obligation, lendingMarket, repayReserve, reserveLiquidityMint, reserveDestinationLiquidity, userSourceLiquidity, tokenProgram, instructionSysvarAccount`
- args: `liquidityAmount: u64`

### `withdrawObligationCollateralAndRedeemReserveCollateral`  ⚠️ RENAMED
- **FLAG:** Build Contract / task intended `withdrawObligationCollateralAndRedeemReserveLiquidity`.
  That name does NOT exist in the IDL. The correct name ends in
  **`...ReserveCollateral`** (not `...ReserveLiquidity`). USE THIS in config.yaml.
- accounts: `owner, obligation, lendingMarket, lendingMarketAuthority, withdrawReserve, reserveLiquidityMint, reserveSourceCollateral, reserveCollateralMint, reserveLiquiditySupply, userDestinationLiquidity, placeholderUserDestinationCollateral, collateralTokenProgram, liquidityTokenProgram, instructionSysvarAccount`
- args: `collateralAmount: u64`

Also present and possibly useful (not configured, FYI):
- `depositReserveLiquidity` (args `liquidityAmount: u64`) - simple deposit.
- `withdrawObligationCollateral` (args `collateralAmount: u64`) - collateral-only withdraw.
- `liquidateObligationAndRedeemReserveCollateral` - klend liquidation, if you want
  Kamino liquidation rows alongside Drift.
- V2 variants exist for most (`...V2`) using the farms-state account layout.

---

## Summary of mismatches to adjust in config.yaml

| Intended name | Actual IDL name | Program |
|---|---|---|
| `withdrawObligationCollateralAndRedeemReserveLiquidity` | `withdrawObligationCollateralAndRedeemReserveCollateral` | Kamino |

Everything else (Jupiter route/sharedAccountsRoute; all 5 Drift; Kamino
deposit/borrow/repay) matches the intended names exactly.
