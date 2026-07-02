-- Deterministic seed for the differential GraphQL suite.
-- Values are chosen to exercise serialization edge cases: unicode, quoting,
-- numeric extremes, Infinity/NaN floats, timestamp precision, jsonb variants,
-- dangling relationship references, and empty arrays.

INSERT INTO public."NftCollection" (id, "contractAddress", name, symbol, "maxSupply", "currentSupply") VALUES
('coll-1', '0x1111111111111111111111111111111111111111', 'Alpha Apes', 'ALPHA', 10000, 3),
('coll-2', '0x2222222222222222222222222222222222222222', 'Béta Bots 🤖', 'BÉTA', 340282366920938463463374607431768211455, 5),
('coll-3', '0x3333333333333333333333333333333333333333', '', '', 0, 0);

INSERT INTO public."User" (id, address, gravatar_id, "updatesCountOnUserForTesting", "accountType") VALUES
('user-1', '0xaaaa000000000000000000000000000000000001', 'grav-1', 0, 'ADMIN'),
('user-2', '0xaaaa000000000000000000000000000000000002', 'grav-2', 42, 'USER'),
('user-3', '0xaaaa000000000000000000000000000000000003', NULL, 2147483647, 'USER'),
('user-4', '0xaaaa000000000000000000000000000000000004', NULL, -2147483648, 'ADMIN'),
('user "quoted" 🚀', '0xaaaa000000000000000000000000000000000005', NULL, 5, 'USER'),
('user-dangling', '0xaaaa000000000000000000000000000000000006', 'grav-missing', 7, 'USER');

INSERT INTO public."Gravatar" (id, owner_id, "displayName", "imageUrl", "updatesCount", size) VALUES
('grav-1', 'user-1', 'First Grav', 'https://example.com/1.png', 3, 'SMALL'),
('grav-2', 'user-2', 'Zwölf Grüße 中文', 'https://example.com/ü.png', 99999999999999999999999999999999999999, 'MEDIUM'),
('grav-3', 'user-missing', 'Dangling owner', 'https://example.com/3.png', 0, 'LARGE');

INSERT INTO public."Token" (id, "tokenId", collection_id, owner_id) VALUES
('tok-1', 0, 'coll-1', 'user-1'),
('tok-2', 1, 'coll-1', 'user-1'),
('tok-3', 2, 'coll-1', 'user-2'),
('tok-4', 1000000000000000000000000000000, 'coll-2', 'user-2'),
('tok-5', -5, 'coll-2', 'user-3'),
('tok-6', 123456789, 'coll-2', 'user-missing'),
('tok-7', 7, 'coll-missing', 'user-1'),
('tok-8', 8, 'coll-2', 'user "quoted" 🚀'),
('tok-9', 9999999999999999999999999999999999999999999999999999999999999999999999999999, 'coll-2', 'user-4'),
('tok-10', 10, 'coll-1', 'user-4');

INSERT INTO public."B" (id, c_id) VALUES
('b-1', 'c-1'),
('b-2', NULL),
('b-3', 'c-missing');

INSERT INTO public."A" (id, b_id, "optionalStringToTestLinkedEntities") VALUES
('a-1', 'b-1', 'linked'),
('a-2', 'b-1', NULL),
('a-3', 'b-2', ''),
('a-4', 'b-missing', 'dangling b');

INSERT INTO public."C" (id, a_id, "stringThatIsMirroredToA") VALUES
('c-1', 'a-1', 'mirror-1'),
('c-2', 'a-2', 'mirror-2');

INSERT INTO public."D" (id, c) VALUES
('d-1', 'c-1'),
('d-2', 'c-1'),
('d-3', 'c-2'),
('d-4', 'c-missing');

INSERT INTO public."EntityWithAllNonArrayTypes"
(id, string, "optString", int_, "optInt", float_, "optFloat", bool, "optBool", "bigInt", "optBigInt", "bigDecimal", "optBigDecimal", "bigDecimalWithConfig", "enumField", "optEnumField", timestamp, "optTimestamp") VALUES
('scalar-1', 'plain', 'present', 1, 10, 1.5, 2.5, true, true, 100, 200, 1.25, 3.75, 1.00000001, 'ADMIN', 'USER', '2024-01-15T12:34:56.789+00', '2024-01-15T12:34:56.789123+00'),
('scalar-nulls', 'has nulls', NULL, 0, NULL, 0, NULL, false, NULL, 0, NULL, 0, NULL, 0, 'USER', NULL, '1970-01-01T00:00:00+00', NULL),
('scalar-extremes', 'extremes', 'x', 2147483647, -2147483648, 1.7976931348623157e308, 5e-324, true, false, 9999999999999999999999999999999999999999999999999999999999999999999999999999, -9999999999999999999999999999999999999999999999999999999999999999999999999999, 12345678901234567890.123456789, -0.000000001, 99.99999999, 'ADMIN', 'ADMIN', '9999-12-31T23:59:59.999999+00', '1969-12-31T23:59:59.999999+00'),
('scalar-special-float', 'inf and nan', NULL, -1, NULL, 'Infinity', 'NaN', false, NULL, 1, NULL, 1.1000, NULL, 0.5, 'USER', NULL, '2000-02-29T00:00:00+00', NULL),
('scalar-neg-inf', 'neg inf', NULL, -2, NULL, '-Infinity', '-0', true, NULL, -1, NULL, -1.5, NULL, -0.00000001, 'USER', NULL, '2024-06-30T23:59:60+00', NULL),
('scalar-unicode', 'héllo wörld 中文测试 🚀🎉', 'emoji 🤖', 7, 7, -3.14159, 2.718281828459045, true, true, 42, -42, 3.14000, 0.00000, 2.50000000, 'USER', 'USER', '2024-12-25T18:30:00+05:30', '2024-12-25T18:30:00-08:00'),
('scalar-quotes', E'with "double" and \'single\' and back\\slash and\nnewline and\ttab', 'end', 3, 3, 0.1, 0.2, false, false, 7, 8, 0.5, 0.5, 3.00000000, 'ADMIN', 'USER', '2024-03-10T10:00:00+00', '2024-03-10T10:00:00+00'),
('scalar-empty', '', '', 4, 0, -0.5, 0, true, false, 10, 0, 100, 0, 0.00000001, 'USER', 'ADMIN', '2024-07-04T00:00:00.1+00', '2024-07-04T00:00:00.12+00');

INSERT INTO public."EntityWithAllTypes"
(id, string, "optString", "arrayOfStrings", int_, "optInt", "arrayOfInts", float_, "optFloat", "arrayOfFloats", bool, "optBool", "bigInt", "optBigInt", "arrayOfBigInts", "bigDecimal", "optBigDecimal", "bigDecimalWithConfig", "arrayOfBigDecimals", timestamp, "optTimestamp", json, "enumField", "optEnumField") VALUES
('all-1', 'first', 'opt', '{"one","two","three"}', 1, 2, '{1,2,3}', 1.5, 2.5, '{1.5,2.5,-3.5}', true, false, 1000, 2000, '{"1","2","3"}', 10.5, 20.5, 1.12345678, '{"1.5","2.25"}', '2024-01-01T00:00:00+00', '2024-01-02T00:00:00+00', '{"kind": "object", "n": 1, "nested": {"a": [1, 2]}}', 'ADMIN', 'USER'),
('all-empty-arrays', 'empty', NULL, '{}', 0, NULL, '{}', 0, NULL, '{}', false, NULL, 0, NULL, '{}', 0, NULL, 0, '{}', '2024-01-01T00:00:00+00', NULL, '{}', 'USER', NULL),
('all-array-edge', 'array edges', 'x', '{"with,comma","with}brace","with\"quote","with''single",""," leading space","emoji 🚀","back\\slash"}', -1, -2, '{-2147483648,0,2147483647}', -1.5, NULL, '{0,-0.5}', true, true, -1, 1, '{"-99999999999999999999999999999999999999","0","99999999999999999999999999999999999999"}', -0.5, 0.5, -1.00000001, '{"-1.5","0.0","1.500"}', '2024-05-05T05:05:05.55555+00', '2024-05-05T05:05:05.555555+00', '[1, "two", null, true, {"k": "v"}, [2.5]]', 'ADMIN', 'ADMIN'),
('all-json-string', 'json scalar string', NULL, '{"a"}', 5, 5, '{5}', 5.5, 5.5, '{5.5}', true, NULL, 5, 5, '{"5"}', 5.5, 5.5, 5.00000000, '{"5.5"}', '2024-02-02T02:02:02+00', NULL, '"just a string"', 'USER', NULL),
('all-json-number', 'json scalar number', NULL, '{"b"}', 6, NULL, '{6}', 6.5, NULL, '{6.5}', false, NULL, 6, NULL, '{"6"}', 6.5, NULL, 6.00000000, '{"6.5"}', '2024-02-03T02:02:02+00', NULL, '123456789012345678901234567890.5', 'USER', NULL),
('all-json-null', 'jsonb null literal', NULL, '{"c"}', 7, NULL, '{7}', 7.5, NULL, '{7.5}', true, NULL, 7, NULL, '{"7"}', 7.5, NULL, 7.00000000, '{"7.5"}', '2024-02-04T02:02:02+00', NULL, 'null', 'ADMIN', NULL),
('all-json-unicode', 'json unicode', NULL, '{"d"}', 8, NULL, '{8}', 8.5, NULL, '{8.5}', false, NULL, 8, NULL, '{"8"}', 8.5, NULL, 8.00000000, '{"8.5"}', '2024-02-05T02:02:02+00', NULL, '{"héllo": "wörld 🚀", "esc": "a\"b\\c\nd", "num": 1e100}', 'USER', NULL),
('all-json-bool', 'json scalar bool', NULL, '{"e"}', 9, NULL, '{9}', 9.5, NULL, '{9.5}', true, NULL, 9, NULL, '{"9"}', 9.5, NULL, 9.00000000, '{"9.5"}', '2024-02-06T02:02:02+00', NULL, 'false', 'USER', NULL);

INSERT INTO public."PostgresNumericPrecisionEntityTester"
(id, "exampleBigInt", "exampleBigIntRequired", "exampleBigIntArray", "exampleBigIntArrayRequired", "exampleBigDecimal", "exampleBigDecimalRequired", "exampleBigDecimalArray", "exampleBigDecimalArrayRequired", "exampleBigDecimalOtherOrder") VALUES
('prec-1',
 9999999999999999999999999999999999999999999999999999999999999999999999999999,
 99999999999999999999999999999999999999999999999999999999999999999999999999999,
 '{1,2,3}',
 '{-1,-2,-3}',
 123456789012345678901234567890123456789012345678901234567890123456789012345.12345,
 -123456789012345678901234567890123456789012345678901234567890123456789012345.54321,
 '{0.00001,-0.00001}',
 '{123.45678}',
 0.123456),
('prec-nulls', NULL, 0, NULL, '{}', NULL, 0, NULL, '{}', 0),
('prec-2', -1, 1, '{0}', '{9999999999}', 1.5, -1.5, '{1.10000}', '{-1.10000}', -0.000001);

INSERT INTO public."EntityWithBigDecimal" (id, "bigDecimal") VALUES
('bd-1', 0),
('bd-2', 1.10),
('bd-3', -1.10),
('bd-4', 123456789.123456789),
('bd-5', 0.000000000000000001);

INSERT INTO public."EntityWithTimestamp" (id, timestamp) VALUES
('ts-epoch', '1970-01-01T00:00:00+00'),
('ts-micro', '2024-01-15T12:34:56.123456+00'),
('ts-milli', '2024-01-15T12:34:56.123+00'),
('ts-pre-epoch', '1969-07-20T20:17:40+00'),
('ts-future', '9999-12-31T23:59:59.999999+00'),
('ts-zoned', '2024-06-15T12:00:00+09:30');

INSERT INTO public."EntityWithRestrictedReScriptField" (id, type) VALUES
('restricted-1', 'the type field'),
('restricted-2', '');

INSERT INTO public."SimpleEntity" (id, value) VALUES
('simple-1', 'v1'),
('simple-2', 'v2'),
('simple-3', 'v3'),
('simple-4', 'v4'),
('simple-5', 'v5'),
('simple-6', 'v6'),
('simple-7', 'v7'),
('simple-8', 'v8'),
('simple-9', 'v9'),
('simple-10', 'v10');

INSERT INTO public."SimulateTestEvent" (id, "blockNumber", "logIndex", timestamp) VALUES
('sim-1', 100, 0, 1700000000),
('sim-2', 100, 1, 1700000000),
('sim-3', 101, 0, 1700000012),
('sim-4', 102, 5, 1700000024),
('sim-5', 103, 2, 1700000036);

INSERT INTO public."CustomSelectionTestPass" (id) VALUES ('custom-1'), ('custom-2');

INSERT INTO public."EntityWith63LenghtName______________________________________one" (id) VALUES ('long-1'), ('long-2');
INSERT INTO public."EntityWith63LenghtName______________________________________two" (id) VALUES ('long-1');

INSERT INTO public.raw_events
(chain_id, event_id, event_name, contract_name, block_number, log_index, src_address, block_hash, block_timestamp, block_fields, transaction_fields, params) VALUES
(1, 4611686018427387904, 'Transfer', 'Gravatar', 10861674, 0, '0x2b2f78c5bf6d9c12ee1225d5f374aa91204580c3', '0xblock1', 1600000000, '{"number": 10861674}', '{"hash": "0xtx1", "transactionIndex": 0}', '{"from": "0x0", "to": "0x1", "value": "100"}'),
(1, 4611686018427387905, 'Transfer', 'Gravatar', 10861674, 1, '0x2b2f78c5bf6d9c12ee1225d5f374aa91204580c3', '0xblock1', 1600000000, '{"number": 10861674}', '{"hash": "0xtx1", "transactionIndex": 0}', '{"from": "0x1", "to": "0x2", "value": "9999999999999999999999999999"}'),
(1, 4611686018427387906, 'NewGravatar', 'Gravatar', 10861675, 0, '0x2b2f78c5bf6d9c12ee1225d5f374aa91204580c3', '0xblock2', 1600000012, '{"number": 10861675}', '{}', '{"id": "1", "displayName": "unicode 🚀", "nested": {"deep": [1, null, "x"]}}'),
(1337, 1, 'EmptyEvent', 'Noop', 1, 0, '0x0000000000000000000000000000000000000000', '0xblockA', 1500000000, '{}', '{}', '{}'),
(1337, 2, 'FilterTestEvent', 'EventFiltersTest', 2, 3, '0x4444444444444444444444444444444444444444', '0xblockB', 1500000060, '{"number": 2, "extra": true}', '{"hash": null}', '{"addr": "0x5555555555555555555555555555555555555555"}');

INSERT INTO public.envio_chains
(id, start_block, end_block, max_reorg_depth, buffer_block, source_block, first_event_block, ready_at, events_processed, _is_hyper_sync, progress_block) VALUES
(1, 0, NULL, 200, 10861774, 10861800, 10861674, '2024-11-01T10:20:30.456+00', 2147487821, true, 10861774),
(1337, 1, 5000, 0, 4000, 4500, NULL, NULL, 0, false, 3999);
