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

---

# Stream B-ext: Orca Whirlpool + Meteora DLMM (2026-05-28)

Added to widen Jupiter-route capture (Jupiter CPIs into many DEXes, not just
Raydium). Config fragment: `idls/orca-meteora-config.yaml`. IDLs: `idls/orca.json`,
`idls/meteora.json`.

## IDL format note (DIFFERS from the three above)

Both Orca + Meteora IDLs are **Anchor 0.30 "spec 0.1.0" format** (NOT legacy):
- Top-level `address`, `metadata: { name, version, spec: "0.1.0" }`.
- Per-instruction **embedded `discriminator` byte arrays** (8 ints) -> converted
  to `0x`-hex below. NOT computed from the name.
- Account objects use `writable` / `signer` keys (not `isMut`/`isSigner`).
- **Instruction names are snake_case** (`swap_v2`, `swap2`), unlike the
  camelCase legacy IDLs above.

How HyperIndex consumes this (verified by reading
`hypersync-client-solana 0.0.3-rc.1::decode/anchor_idl.rs` +
`cli/src/config_parsing/system_config.rs`):
- The parser keys the instruction table by **discriminator bytes**. For 0.30
  IDLs it reads the embedded array; only legacy IDLs fall back to
  `sha256("global:"+snake_case(name))[..8]`.
- `resolve_instruction_layout` matches the config-side `discriminator:` hex
  against that map. The config `name:` is the **handler/event label only** and
  is NOT cross-checked against the IDL instruction name. So the discriminator is
  the load-bearing field; the `name` just needs to be a valid, unique ReScript
  identifier (snake_case is fine). We use the IDL-exact snake_case names.
- Sanity: every embedded discriminator below was confirmed equal to
  `sha256("global:"+name)[..8]`.

| Program | File | Size | Version (metadata.name) | Format |
|---|---|---|---|---|
| Orca Whirlpool | `orca.json` | 194 KB | 0.9.0 (`whirlpool`) | Anchor 0.30 spec 0.1.0 |
| Meteora DLMM | `meteora.json` | 211 KB | 0.12.0 (`lb_clmm`) | Anchor 0.30 spec 0.1.0 |

Sources:
- orca.json:    fetched from the **on-chain Anchor IDL account** (PDA
  `2KFqE4RWoPVbvodo8vbggCFeHPS8TDvgpwp79ALMrcyn`) via mainnet RPC `getAccountInfo`
  + zlib-inflate. The orca-so/whirlpools repo no longer commits a plain IDL JSON
  (codama reads a gitignored `target/idl/whirlpool.json`), so the deployed
  program's own IDL is the canonical source.
- meteora.json: https://raw.githubusercontent.com/MeteoraAg/dlmm-sdk/main/ts-client/src/dlmm/idl/idl.json

---

## Orca Whirlpool (`whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc`)

Both wanted swap instructions present.

### `swap`  (config name `swap`)
- discriminator: **`0xf8c69e91e17587c8`**  (embedded; == sha256(global:swap))
- args: `amount: u64`, `other_amount_threshold: u64`, `sqrt_price_limit: u128`,
  `amount_specified_is_input: bool`, `a_to_b: bool`
  (`amount` is in or out depending on `amount_specified_is_input`; `a_to_b` gives
  direction. Pair with `other_amount_threshold` for the min-out / max-in bound.)
- accounts (ordered): `token_program, token_authority(signer), whirlpool(mut),
  token_owner_account_a(mut), token_vault_a(mut), token_owner_account_b(mut),
  token_vault_b(mut), tick_array_0(mut), tick_array_1(mut), tick_array_2(mut),
  oracle, whirlpool_program`
  - VALUE: vaults `token_vault_a` / `token_vault_b` are the pool token accounts;
    `token_owner_account_a/b` are the trader's ATAs. Mints are NOT named directly
    in v1 swap (resolve via tokenBalances on the vault/owner accounts).

### `swap_v2`  (config name `swap_v2`)
- discriminator: **`0x2b04ed0b1ac91e62`**  (embedded; == sha256(global:swap_v2))
- args: same five as `swap` plus
  `remaining_accounts_info: Option<RemainingAccountsInfo>` (token-2022 transfer
  hooks; defined in IDL `types`).
- accounts (ordered): `token_program_a, token_program_b, memo_program,
  token_authority(signer), whirlpool(mut), token_mint_a, token_mint_b,
  token_owner_account_a(mut), token_vault_a(mut), token_owner_account_b(mut),
  token_vault_b(mut), tick_array_0(mut), tick_array_1(mut), tick_array_2(mut),
  oracle(mut), whirlpool_program`
  - VALUE: **mints named directly** here -> `token_mint_a` / `token_mint_b`.

CAVEAT: on-chain IDL is v0.9.0 (the IDL account can lag the deployed program).
Account order + args were cross-checked against the current
`legacy-sdk/whirlpool/src/instructions/swap-ix.ts` on main and match. The
discriminator is name-derived so it is correct regardless of any account drift.
Other swap variants present (not configured): `two_hop_swap` `0xc360ed6c44a2dbe6`,
`two_hop_swap_v2` `0xba8fd11dfe02c275`.

---

## Meteora DLMM / lb_clmm (`LBUZKhRxPF3XUpBCjp4YzTKgLccjZhTSDM9YuVaPwxo`)

Wanted `swap` present; `swap2`, `swapExactOut` (snake `swap_exact_out`) also
present and configured.

### `swap`  (config name `swap`)
- discriminator: **`0xf8c69e91e17587c8`**  (embedded; == sha256(global:swap))
  NOTE: identical bytes to Orca `swap` (both `sha256("global:swap")`). Harmless -
  dispatch is per-program (program_id scopes the discriminator), so no collision.
- args: `amount_in: u64`, `min_amount_out: u64`
- accounts (ordered): `lb_pair(mut), bin_array_bitmap_extension(mut,optional),
  reserve_x(mut), reserve_y(mut), user_token_in(mut), user_token_out(mut),
  token_x_mint, token_y_mint, oracle(mut), host_fee_in(mut,optional),
  user(signer), token_x_program, token_y_program, event_authority, program`
  - VALUE: **mints named** `token_x_mint` / `token_y_mint`; pool vaults
    `reserve_x` / `reserve_y`; trader sides `user_token_in` / `user_token_out`.

### `swap2`  (config name `swap2`)
- discriminator: **`0x414b3f4ceb5b5b88`**  (embedded; == sha256(global:swap2))
- args: `amount_in: u64`, `min_amount_out: u64`,
  `remaining_accounts_info: RemainingAccountsInfo`
- accounts: same as `swap` but inserts `memo_program` before
  `event_authority` (16 accounts total): `..., token_x_program, token_y_program,
  memo_program, event_authority, program`.

### `swap_exact_out`  (config name `swapExactOut`)
- discriminator: **`0xfa49652126cf4bb8`**  (embedded; == sha256(global:swap_exact_out))
- args: `max_in_amount: u64`, `out_amount: u64`
- accounts: identical ordering to `swap` (15 accounts).

Other swap variants present (not configured, FYI):
- `swap_exact_out2`        `0x2bd7f784893cf351`  (adds `remaining_accounts_info` + `memo_program`)
- `swap_with_price_impact` `0x38ade6d0ade49ccd`  (args `amount_in: u64`, `active_id: Option<i32>`, `max_price_impact_bps: u16`)
- `swap_with_price_impact2` `0x4a62c0d6b1334b33` (+ `remaining_accounts_info`)

---

## Stream B-ext discriminator quick-reference

| Program | config name | 0x discriminator | args (amount fields) |
|---|---|---|---|
| Orca    | `swap`           | `0xf8c69e91e17587c8` | amount, other_amount_threshold (u64) |
| Orca    | `swap_v2`        | `0x2b04ed0b1ac91e62` | amount, other_amount_threshold (u64) |
| Meteora | `swap`           | `0xf8c69e91e17587c8` | amount_in, min_amount_out (u64) |
| Meteora | `swap2`          | `0x414b3f4ceb5b5b88` | amount_in, min_amount_out (u64) |
| Meteora | `swap_exact_out` | `0xfa49652126cf4bb8` | max_in_amount, out_amount (u64) |
