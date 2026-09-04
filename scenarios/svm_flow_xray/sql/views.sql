-- =====================================================================
-- Flow X-Ray custom SQL view layer (Stream C)
-- =====================================================================
--
-- NAMING CONVENTION (verified against HyperIndex codegen + generated
-- .envio/types.d.ts on 2026-05-28):
--   * Entity tables live in schema "public" (default; override via
--     ENVIO_PG_SCHEMA / ENVIO_PG_PUBLIC_SCHEMA).
--   * Table name == GraphQL type name VERBATIM, double-quoted PascalCase:
--       public."InstructionNode", public."TokenDelta", public."FlowTx",
--       public."LiquidationEvent", public."IndexerStats"
--   * Column name == GraphQL field name VERBATIM, double-quoted camelCase:
--       "txSig", "addrPath", "parentPath", "feePayer", "delta", ...
--     (linked-entity fields would get a _id suffix, but this schema has none.)
--   * Column types: String->text, Int->integer, BigInt->numeric,
--     Boolean->boolean.
--
-- This script is IDEMPOTENT / re-runnable. Codegen recreates the entity
-- tables on every `pnpm codegen`, so re-apply this afterwards (see
-- apply-views.sh). Plain views use CREATE OR REPLACE; materialized views
-- are dropped + recreated so column-set changes don't error.
--
-- VERIFY against live DB if anything misbehaves: the camelCase column
-- quoting and the public schema name. Both are confirmed from codegen,
-- but a custom ENVIO_PG_SCHEMA changes the schema only (column names are
-- unaffected).
-- =====================================================================

-- ---------------------------------------------------------------------
-- (a) Static price map for top mints.
--     usd_price is approximate (snapshot, hackathon demo) - good enough
--     to make "gross USD" thresholds meaningful. Mint addresses are the
--     canonical SPL mints (verified). Unknown mints resolve to 0 USD via
--     LEFT JOIN, so thresholds stay conservative.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.mint_price (
  mint      text PRIMARY KEY,
  symbol    text,
  usd_price numeric,
  decimals  int
);

-- Re-seed every apply so price tweaks propagate. TRUNCATE keeps the table
-- (and any GraphQL tracking) intact while replacing rows.
TRUNCATE public.mint_price;

INSERT INTO public.mint_price (mint, symbol, usd_price, decimals) VALUES
  -- Stables (price pinned to 1.0)
  ('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v', 'USDC',    1.0,   6),
  ('Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB', 'USDT',    1.0,   6),
  ('2b1kV6DkPAnxd5ixfnxCpjxmKwqjjaYmCZfHsFu24GXo', 'PYUSD',   1.0,   6),
  -- SOL + liquid staking derivatives
  ('So11111111111111111111111111111111111111112',  'wSOL',    150.0, 9),
  ('mSoLzYCxHdYgdzU16g5QSh3i5K3z3KZK7ytfqcJm7So',  'mSOL',    185.0, 9),
  ('J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn', 'JitoSOL', 180.0, 9),
  -- Majors / memes (approx spot, snapshot)
  ('JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN',  'JUP',     0.55,  6),
  ('4k3Dyjzvzp8eMZWUXbBCjEvwSkkk59S5iCNLY3QrkX6R', 'RAY',     2.50,  6),
  ('DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263', 'BONK',    0.000022, 5),
  ('EKpQGSJtjMFqKZ9KQanSqYXRcF8fBopzLHYxdM65zcjm', 'WIF',     1.80,  6);

-- TODO (add ONLY with verified mint addresses): jitoSOL alt mints,
-- additional stables (FDUSD, USDS), other LSTs (bSOL, INF). Wrong
-- addresses are worse than missing ones, so leave unverified mints out.

-- ---------------------------------------------------------------------
-- Convenience: usd_value(mint, raw_amount) as an inline CTE pattern.
-- Postgres has no cheap "expression macro", so each value view LEFT JOINs
-- mint_price and computes:  raw_amount / 10^decimals * usd_price.
-- Unknown mint -> NULL price -> coalesced to 0.
--
-- Slot -> unix milliseconds (approximate, for time bucketing only):
--   unix_ms = 1780000000000 + (slot - 422700000) * 400
--   (anchor ~2026-05-28; 400ms/slot). Inlined where needed.
-- ---------------------------------------------------------------------

-- =====================================================================
-- (b) Views - ordered so dependencies come first.
-- =====================================================================

-- v_protocol_edge: parent.program -> child.program edge counts.
-- A child node's parentPath equals its parent's addrPath within the same tx.
CREATE OR REPLACE VIEW public.v_protocol_edge AS
SELECT
  parent."program"  AS src_program,
  child."program"   AS dst_program,
  count(*)          AS edge_count,
  count(DISTINCT child."txSig") AS tx_count
FROM public."InstructionNode" AS child
JOIN public."InstructionNode" AS parent
  ON  child."txSig"       = parent."txSig"
  AND child."parentPath"  = parent."addrPath"
WHERE child."parentPath" IS NOT NULL
GROUP BY parent."program", child."program";

-- v_tx_flow: per-tx protocol set, protocol_count, max_depth, ix_count.
CREATE OR REPLACE VIEW public.v_tx_flow AS
SELECT
  n."txSig"                                  AS tx_sig,
  max(n."slot")                              AS slot,
  max(n."feePayer")                          AS fee_payer,
  array_agg(DISTINCT n."program" ORDER BY n."program") AS programs,
  count(DISTINCT n."program")                AS protocol_count,
  max(n."depth")                             AS max_depth,
  count(*)                                   AS ix_count,
  bool_or(lower(n."ixName") LIKE '%liquidate%') AS has_liquidation,
  (1780000000000 + (max(n."slot") - 422700000) * 400)::bigint AS unix_ms
FROM public."InstructionNode" AS n
GROUP BY n."txSig";

-- v_tx_value: per-tx gross moved (token units + USD) and distinct mints.
-- Gross USD sums abs(delta) priced via mint_price; unknown mints contribute 0.
CREATE OR REPLACE VIEW public.v_tx_value AS
SELECT
  d."txSig"                          AS tx_sig,
  max(d."slot")                      AS slot,
  sum(abs(d."delta"))                AS gross_raw,
  count(DISTINCT d."mint")           AS distinct_mints,
  count(DISTINCT d."owner")          AS distinct_owners,
  COALESCE(
    sum(
      abs(d."delta")
      / power(10::numeric, COALESCE(p.decimals, 0))
      * COALESCE(p.usd_price, 0)
    ),
    0
  )                                  AS gross_usd
FROM public."TokenDelta" AS d
LEFT JOIN public.mint_price AS p ON p.mint = d."mint"
GROUP BY d."txSig";

-- v_whale_loop: feePayer/owner net ~0 but big gross (in-and-out / round-trip).
-- Per (tx, owner): net = sum(delta), gross = sum(abs(delta)) priced in USD.
-- "Loop" = large gross USD with small net relative to gross.
CREATE OR REPLACE VIEW public.v_whale_loop AS
SELECT
  loop.tx_sig,
  loop.slot,
  loop.owner,
  loop.net_usd,
  loop.gross_usd,
  loop.distinct_mints
FROM (
  SELECT
    d."txSig"                 AS tx_sig,
    max(d."slot")             AS slot,
    d."owner"                 AS owner,
    count(DISTINCT d."mint")  AS distinct_mints,
    sum(
      (d."delta")
      / power(10::numeric, COALESCE(p.decimals, 0))
      * COALESCE(p.usd_price, 0)
    )                         AS net_usd,
    sum(
      abs(d."delta")
      / power(10::numeric, COALESCE(p.decimals, 0))
      * COALESCE(p.usd_price, 0)
    )                         AS gross_usd
  FROM public."TokenDelta" AS d
  LEFT JOIN public.mint_price AS p ON p.mint = d."mint"
  WHERE d."owner" IS NOT NULL
  GROUP BY d."txSig", d."owner"
) AS loop
-- THRESHOLDS: gross > $100k AND |net| < 5% of gross (round-trip signature).
WHERE loop.gross_usd > 100000
  AND abs(loop.net_usd) < 0.05 * loop.gross_usd;

-- v_interesting_tx: the flags feed. Joins flow + value; surfaces the
-- cross-protocol / whale / arb / liquidation signals.
CREATE OR REPLACE VIEW public.v_interesting_tx AS
SELECT
  f.tx_sig,
  f.slot,
  f.unix_ms,
  f.fee_payer,
  f.programs,
  f.protocol_count,
  f.max_depth,
  f.ix_count,
  COALESCE(v.gross_raw, 0)        AS gross_raw,
  COALESCE(v.gross_usd, 0)        AS gross_usd,
  COALESCE(v.distinct_mints, 0)   AS distinct_mints,
  -- flags (thresholds inline + parameterizable here)
  (f.protocol_count >= 3)                              AS is_cross_protocol,
  (COALESCE(v.gross_usd, 0) > 100000)                  AS is_whale,
  -- arb-like: multi-protocol, several mints, and value moved (loop-ish)
  (f.protocol_count >= 2
     AND COALESCE(v.distinct_mints, 0) >= 2
     AND COALESCE(v.gross_usd, 0) > 10000)             AS is_arb_like,
  f.has_liquidation                                    AS has_liquidation,
  -- interest_score: composite ranking so the feed leads with whales / cross-
  -- protocol / liquidations instead of just whatever happens to be at the head
  -- slot. Weight order: liquidation > whale > cross-protocol > arb shape >
  -- log(gross_usd) as a tie-breaker.
  (
    CASE WHEN f.has_liquidation               THEN 5000 ELSE 0 END +
    CASE WHEN COALESCE(v.gross_usd, 0) > 100000 THEN 4000 ELSE 0 END +
    CASE WHEN f.protocol_count >= 3           THEN 2000 ELSE 0 END +
    CASE WHEN f.protocol_count >= 2
              AND COALESCE(v.distinct_mints, 0) >= 2
              AND COALESCE(v.gross_usd, 0) > 10000 THEN 1000 ELSE 0 END +
    LEAST(500, ln(COALESCE(v.gross_usd, 0) + 1) * 30)::int
  )                                                    AS interest_score
FROM public.v_tx_flow AS f
LEFT JOIN public.v_tx_value AS v ON v.tx_sig = f.tx_sig
WHERE f.protocol_count >= 2          -- baseline: only multi-protocol txs are "interesting"
   OR COALESCE(v.gross_usd, 0) > 100000
   OR f.has_liquidation;

-- =====================================================================
-- (c) Materialized views. Refresh after each backfill catch-up:
--       REFRESH MATERIALIZED VIEW public.mv_liq_cascade;
--       REFRESH MATERIALIZED VIEW public.mv_drift_contagion;
--     (apply-views.sh refreshes them at the end.)
--     CREATE ... IF NOT EXISTS keeps re-runs cheap; we DROP first so a
--     changed column set never errors on re-apply.
-- =====================================================================

-- mv_liq_cascade: liquidations clustered per slot bucket (~10s buckets).
-- Bucket = floor(slot / 25) (25 slots * 400ms ~= 10s). Cascade = many
-- liquidations landing in the same window (contagion timeline source).
DROP MATERIALIZED VIEW IF EXISTS public.mv_liq_cascade;
CREATE MATERIALIZED VIEW IF NOT EXISTS public.mv_liq_cascade AS
SELECT
  (l."slot" / 25)                          AS slot_bucket,
  min(l."slot")                            AS bucket_start_slot,
  max(l."slot")                            AS bucket_end_slot,
  (1780000000000 + (min(l."slot") - 422700000) * 400)::bigint AS bucket_start_ms,
  count(*)                                 AS liq_count,
  count(DISTINCT l."txSig")                AS tx_count,
  count(DISTINCT l."marketIndex")          AS distinct_markets,
  sum(COALESCE(l."liabilityAmount", 0))    AS total_liability_raw,
  array_agg(DISTINCT l."ixName")           AS liq_kinds
FROM public."LiquidationEvent" AS l
GROUP BY (l."slot" / 25)
ORDER BY (l."slot" / 25);

-- mv_drift_contagion: programs co-occurring with Drift in the same tx,
-- ranked (Ring-3 money shot). For each tx that touches Drift, count the
-- other programs present and the value moved in those txs.
DROP MATERIALIZED VIEW IF EXISTS public.mv_drift_contagion;
CREATE MATERIALIZED VIEW IF NOT EXISTS public.mv_drift_contagion AS
WITH drift_txs AS (
  SELECT DISTINCT n."txSig" AS tx_sig
  FROM public."InstructionNode" AS n
  WHERE n."program" = 'Drift'
),
co_programs AS (
  SELECT
    n."program"            AS program,
    n."txSig"              AS tx_sig
  FROM public."InstructionNode" AS n
  JOIN drift_txs dt ON dt.tx_sig = n."txSig"
  WHERE n."program" <> 'Drift'
  GROUP BY n."program", n."txSig"
)
SELECT
  cp.program,
  count(DISTINCT cp.tx_sig)                       AS tx_count,
  COALESCE(sum(v.gross_usd), 0)                   AS total_gross_usd,
  COALESCE(avg(v.gross_usd), 0)                   AS avg_gross_usd
FROM co_programs cp
LEFT JOIN public.v_tx_value v ON v.tx_sig = cp.tx_sig
GROUP BY cp.program
ORDER BY tx_count DESC, total_gross_usd DESC;
