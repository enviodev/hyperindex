-- Extra volume for benchmarks (applied on top of seed.sql):
-- 10k users, 50 collections, 200k tokens, 20k gravatars, 100k raw_events.
-- Deterministic (generate_series, no random()).

INSERT INTO public."User" (id, address, gravatar_id, "updatesCountOnUserForTesting", "accountType")
SELECT
  'bench-user-' || i,
  '0x' || lpad(to_hex(i), 40, '0'),
  CASE WHEN i % 2 = 0 THEN 'bench-grav-' || (i / 2) ELSE NULL END,
  i % 1000,
  CASE WHEN i % 7 = 0 THEN 'ADMIN' ELSE 'USER' END::public.accounttype
FROM generate_series(1, 10000) i;

INSERT INTO public."Gravatar" (id, owner_id, "displayName", "imageUrl", "updatesCount", size)
SELECT
  'bench-grav-' || i,
  'bench-user-' || (i * 2),
  'Bench Gravatar ' || i,
  'https://example.com/bench/' || i || '.png',
  (i::numeric * 1000000000000000000),
  (ARRAY['SMALL','MEDIUM','LARGE'])[1 + i % 3]::public.gravatarsize
FROM generate_series(1, 5000) i;

INSERT INTO public."NftCollection" (id, "contractAddress", name, symbol, "maxSupply", "currentSupply")
SELECT
  'bench-coll-' || i,
  '0x' || lpad(to_hex(i + 1000000), 40, 'c'),
  'Bench Collection ' || i,
  'B' || i,
  (i::numeric) * 10000000000,
  i * 100
FROM generate_series(1, 50) i;

INSERT INTO public."Token" (id, "tokenId", collection_id, owner_id)
SELECT
  'bench-tok-' || i,
  (i::numeric * 31) % 1000000007,
  'bench-coll-' || (1 + i % 50),
  'bench-user-' || (1 + i % 10000)
FROM generate_series(1, 200000) i;

INSERT INTO public.raw_events
(chain_id, event_id, event_name, contract_name, block_number, log_index, src_address, block_hash, block_timestamp, block_fields, transaction_fields, params)
SELECT
  1 + i % 3,
  4611686018427387904::bigint + i,
  (ARRAY['Transfer','Approval','NewGravatar','UpdatedGravatar'])[1 + i % 4],
  'Gravatar',
  10000000 + i / 10,
  i % 10,
  '0x' || lpad(to_hex(i % 1000), 40, '0'),
  '0x' || lpad(to_hex(i / 10), 64, 'b'),
  1600000000 + (i / 10) * 12,
  json_build_object('number', 10000000 + i / 10)::jsonb,
  json_build_object('hash', '0x' || lpad(to_hex(i), 64, 'a'), 'transactionIndex', i % 100)::jsonb,
  json_build_object('from', '0x' || lpad(to_hex(i % 500), 40, '0'), 'to', '0x' || lpad(to_hex(i % 700), 40, '0'), 'value', (i::numeric * 1000000000)::text)::jsonb
FROM generate_series(1, 100000) i;

ANALYZE public."User", public."Gravatar", public."NftCollection", public."Token", public.raw_events;
