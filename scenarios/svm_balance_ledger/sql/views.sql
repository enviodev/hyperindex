-- =====================================================================
-- Balance Ledger query layer
-- =====================================================================
--
-- Entity tables are created by codegen in schema "public" (override with
-- ENVIO_PG_SCHEMA / ENVIO_PG_PUBLIC_SCHEMA). Table names are the GraphQL
-- type names verbatim and column names the field names verbatim, both
-- double-quoted: public."BalanceChange"."postAmount". BigInt maps to
-- numeric, Int to integer, String to text.
--
-- Codegen recreates the entity tables on every run, which drops dependent
-- views, so re-apply this file afterwards:
--   psql -h localhost -p 5433 -U postgres -d envio-dev -f sql/views.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- The balance of one token account as of a slot. This is the query that
-- has no RPC equivalent: getTokenAccountBalance answers for the current
-- slot only, and the historical answer otherwise needs an archive node
-- replaying the account.
--
-- Returns NULL for an account with no change at or before the slot —
-- either outside the indexed window, or not yet in existence.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.balance_at(account text, at_slot integer)
RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT c."postAmount"
  FROM public."BalanceChange" c
  WHERE c."account" = balance_at.account
    AND c."slot" <= balance_at.at_slot
  ORDER BY c."slot" DESC, c."txIndex" DESC
  LIMIT 1;
$$;

-- ---------------------------------------------------------------------
-- Every holder of a mint as of a slot, largest first. Same idea applied
-- across accounts: the last change at or before the slot wins.
--
-- The RPC equivalent is getProgramAccounts with a mint filter, which
-- answers for the current slot and scans every token account on the
-- cluster to do it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.holders_at(mint text, at_slot integer)
RETURNS TABLE (account text, owner text, amount numeric, decimals integer, slot integer)
LANGUAGE sql STABLE AS $$
  SELECT DISTINCT ON (c."account")
    c."account", c."owner", c."postAmount", c."decimals", c."slot"
  FROM public."BalanceChange" c
  WHERE c."mint" = holders_at.mint
    AND c."slot" <= holders_at.at_slot
  ORDER BY c."account", c."slot" DESC, c."txIndex" DESC;
$$;

-- ---------------------------------------------------------------------
-- The ledger auditing itself. `expectedPre` is the balance carried
-- forward from the account's previous change; a row here is one the
-- matched instruction set failed to account for, which means some way of
-- moving a token amount is missing from config.yaml.
--
-- An empty result is the claim the demo rests on.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_ledger_gap AS
SELECT
  c."account", c."mint", c."slot", c."txIndex", c."txSig",
  c."expectedPre", c."preAmount",
  c."preAmount" - c."expectedPre" AS "unexplained"
FROM public."BalanceChange" c
WHERE NOT c."continuous"
ORDER BY c."slot", c."txIndex";

-- ---------------------------------------------------------------------
-- Net supply change per mint, derived without ever reading a mint
-- account. Transfers cancel out across their two sides, so what survives
-- is minting, burning, and wrapped-SOL syncing.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_mint_supply_change AS
SELECT
  f."mint",
  count(*) AS "transactions",
  sum(f."sumDelta") AS "netSupplyChange",
  count(*) FILTER (WHERE NOT f."conserving") AS "supplyChangingTxs"
FROM public."TxMintFlow" f
GROUP BY f."mint"
ORDER BY abs(sum(f."sumDelta")) DESC;

-- ---------------------------------------------------------------------
-- Accounts that moved the most in the indexed window, by number of
-- changes and by distance travelled from their opening balance.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_account_activity AS
SELECT
  a."id" AS "account",
  a."mint", a."owner", a."decimals",
  a."balance",
  a."openingBalance",
  a."balance" - a."openingBalance" AS "netChange",
  a."changeCount",
  a."gapCount",
  a."openingSlot", a."lastSlot"
FROM public."TokenAccount" a
ORDER BY a."changeCount" DESC, abs(a."balance" - a."openingBalance") DESC;
