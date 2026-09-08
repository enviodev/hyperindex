-- =====================================================================
-- Balance Ledger query layer (ClickHouse)
-- =====================================================================
--
-- Codegen creates, per entity, an append-only `envio_history_<Entity>`
-- table and an `<Entity>` view that collapses it to the latest state at
-- or before the committed checkpoint. Everything below reads the views,
-- so a query never sees a partially-committed batch.
--
-- A GraphQL BigInt is stored as String, which is why amounts are cast
-- before they are summed or ordered — lexicographic order on a decimal
-- string is not numeric order.
--
-- Apply with:
--   clickhouse-client --queries-file sql/clickhouse.sql
-- or over HTTP:
--   curl "$CH_URL" --data-binary @sql/clickhouse.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- The balance of one token account as of a slot. This is the query with
-- no RPC equivalent: getTokenAccountBalance answers for the current slot
-- only, and the historical answer otherwise needs an archive node
-- replaying the account.
--
-- The ClickHouse sort key is (account, slot, txIndex), so this reads a
-- primary-key range rather than searching.
--
--   SELECT * FROM balance_at(account = '...', at_slot = 422300500);
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW balance_at AS
SELECT
  account,
  argMax(postAmount, (slot, txIndex)) AS amount,
  argMax(mint, (slot, txIndex)) AS mint,
  argMax(owner, (slot, txIndex)) AS owner,
  any(decimals) AS decimals,
  max(slot) AS asOfSlot,
  count() AS changes
FROM BalanceChange
WHERE account = {account:String} AND slot <= {at_slot:Int32}
GROUP BY account;

-- ---------------------------------------------------------------------
-- Every holder of a mint as of a slot, largest first. The RPC equivalent
-- is getProgramAccounts with a mint filter, which answers for the current
-- slot and scans every token account on the cluster to do it.
--
--   SELECT * FROM holders_at(mint = '...', at_slot = 422300500) LIMIT 20;
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW holders_at AS
SELECT
  account,
  owner,
  amount,
  decimals,
  amount / pow(10, decimals) AS uiAmount,
  lastSlot,
  changes
FROM (
  SELECT
    account,
    argMax(owner, (slot, txIndex)) AS owner,
    toInt256(argMax(postAmount, (slot, txIndex))) AS amount,
    any(decimals) AS decimals,
    max(slot) AS lastSlot,
    count() AS changes
  FROM BalanceChange
  WHERE mint = {mint:String} AND slot <= {at_slot:Int32}
  GROUP BY account
)
WHERE amount > 0
ORDER BY amount DESC;

-- ---------------------------------------------------------------------
-- One account's whole timeline, oldest first — what the UI plots.
--
--   SELECT * FROM account_history(account = '...');
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW account_history AS
SELECT
  slot,
  txIndex,
  txSig,
  mint,
  decimals,
  toInt256(preAmount) AS preAmount,
  toInt256(postAmount) AS postAmount,
  toInt256(delta) AS delta,
  toInt256(postAmount) / pow(10, decimals) AS uiBalance,
  continuous,
  isOpening
FROM BalanceChange
WHERE account = {account:String}
ORDER BY slot, txIndex;

-- ---------------------------------------------------------------------
-- The ledger auditing itself. `expectedPre` is the balance carried
-- forward from the account's previous change; a row here is one the
-- matched instruction set failed to account for, which means some way of
-- moving a token amount is missing from config.yaml.
--
-- An empty result is the claim the demo rests on.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_ledger_gap AS
SELECT
  account, mint, slot, txIndex, txSig,
  toInt256(expectedPre) AS expectedPre,
  toInt256(preAmount) AS preAmount,
  toInt256(preAmount) - toInt256(expectedPre) AS unexplained
FROM BalanceChange
WHERE NOT continuous
ORDER BY slot, txIndex;

-- ---------------------------------------------------------------------
-- Net supply change per mint, derived without ever reading a mint
-- account. Transfers cancel out across their two sides, so what survives
-- is minting, burning, and wrapped-SOL syncing.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_mint_supply_change AS
SELECT
  f.mint AS mint,
  count() AS transactions,
  sum(toInt256(f.sumDelta)) AS netSupplyChange,
  sum(f.accountsTouched) AS accountsTouched,
  any(d.decimals) AS decimals
FROM TxMintFlow AS f
LEFT JOIN (
  SELECT mint, any(decimals) AS decimals FROM BalanceChange GROUP BY mint
) AS d ON f.mint = d.mint
GROUP BY f.mint
ORDER BY abs(netSupplyChange) DESC;

-- ---------------------------------------------------------------------
-- The conservation check. A transaction conserves only if every token
-- instruction it carried was a classic SPL Token transfer, so the fold
-- the handler deliberately does not do is this join. Every row must have
-- sumDelta = 0.
--
-- Token-2022 is excluded by `conserves` on purpose: a Token-2022 mint can
-- carry a transfer fee, and the withheld part lands in the destination's
-- withheld field rather than its amount.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_conservation_check AS
SELECT
  f.txSig AS txSig,
  f.mint AS mint,
  f.slot AS slot,
  toInt256(f.sumDelta) AS sumDelta,
  f.accountsTouched AS accountsTouched
FROM TxMintFlow AS f
INNER JOIN (
  SELECT txSig FROM TxTokenInstruction GROUP BY txSig HAVING min(conserves) = 1
) AS c ON f.txSig = c.txSig;

-- ---------------------------------------------------------------------
-- Headline numbers, one row. Drives the UI's summary tiles.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_ledger_summary AS
SELECT
  count() AS changes,
  uniqExact(account) AS accounts,
  uniqExact(mint) AS mints,
  uniqExact(txSig) AS transactions,
  min(slot) AS firstSlot,
  max(slot) AS lastSlot,
  countIf(NOT continuous) AS gaps
FROM BalanceChange;
