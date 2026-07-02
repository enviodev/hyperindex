import { defineCases } from "../corpus.js";

// Exhaustive where-operator matrix per scalar type. Complementary operators
// (op and its negation) are paired as aliased roots in one case so the
// snapshot pins that the negative operator is the exact complement on
// NOT NULL columns.
export default defineCases([
  // ── text (User.address) ──────────────────────────────────────────────
  {
    name: "wm-text-eq-neq",
    query: `{ eq: User(where: {address: {_eq: "0xaaaa000000000000000000000000000000000003"}}, order_by: {id: asc}) { id address } neq: User(where: {address: {_neq: "0xaaaa000000000000000000000000000000000003"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-text-gt-gte",
    query: `{ gt: User(where: {address: {_gt: "0xaaaa000000000000000000000000000000000004"}}, order_by: {id: asc}) { id } gte: User(where: {address: {_gte: "0xaaaa000000000000000000000000000000000004"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-text-lt-lte",
    query: `{ lt: User(where: {address: {_lt: "0xaaaa000000000000000000000000000000000002"}}, order_by: {id: asc}) { id } lte: User(where: {address: {_lte: "0xaaaa000000000000000000000000000000000002"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-text-in-nin",
    query: `{ in: User(where: {address: {_in: ["0xaaaa000000000000000000000000000000000002", "0xaaaa000000000000000000000000000000000005", "0xmissing"]}}, order_by: {id: asc}) { id } nin: User(where: {address: {_nin: ["0xaaaa000000000000000000000000000000000002", "0xaaaa000000000000000000000000000000000005", "0xmissing"]}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-text-is-null",
    query: `{ isNull: User(where: {address: {_is_null: true}}, order_by: {id: asc}) { id } notNull: User(where: {address: {_is_null: false}}, order_by: {id: asc}) { id } }`,
  },
  {
    // _nin: [] excludes nothing — every row matches, same as no filter.
    name: "wm-text-nin-empty",
    query: `{ SimpleEntity(where: {id: {_nin: []}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-text-like-nlike",
    query: `{ like: User(where: {address: {_like: "%00000_"}}, order_by: {id: asc}) { id } nlike: User(where: {address: {_nlike: "%00000_"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-text-ilike-nilike",
    query: `{ ilike: User(where: {address: {_ilike: "0XAAAA%3"}}, order_by: {id: asc}) { id } nilike: User(where: {address: {_nilike: "0XAAAA%3"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-text-similar-nsimilar",
    query: `{ similar: User(where: {address: {_similar: "0xaaaa%(1|2)"}}, order_by: {id: asc}) { id } nsimilar: User(where: {address: {_nsimilar: "0xaaaa%(1|2)"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-text-regex-nregex",
    query: `{ regex: User(where: {address: {_regex: "000[12]$"}}, order_by: {id: asc}) { id } nregex: User(where: {address: {_nregex: "000[12]$"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-text-iregex-niregex",
    query: `{ iregex: User(where: {address: {_iregex: "^0XAAAA.*[56]$"}}, order_by: {id: asc}) { id } niregex: User(where: {address: {_niregex: "^0XAAAA.*[56]$"}}, order_by: {id: asc}) { id } }`,
  },

  // ── Int (User.updatesCountOnUserForTesting / SimulateTestEvent) ──────
  {
    name: "wm-int-eq-neq",
    query: `{ eq: SimulateTestEvent(where: {blockNumber: {_eq: 100}}, order_by: {id: asc}) { id blockNumber } neq: SimulateTestEvent(where: {blockNumber: {_neq: 100}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-int-gt-gte",
    query: `{ gt: SimulateTestEvent(where: {logIndex: {_gt: 1}}, order_by: {id: asc}) { id logIndex } gte: SimulateTestEvent(where: {logIndex: {_gte: 1}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-int-lt-lte",
    query: `{ lt: User(where: {updatesCountOnUserForTesting: {_lt: 5}}, order_by: {id: asc}) { id updatesCountOnUserForTesting } lte: User(where: {updatesCountOnUserForTesting: {_lte: 5}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-int-in-nin",
    query: `{ in: User(where: {updatesCountOnUserForTesting: {_in: [0, 7, 2147483647]}}, order_by: {id: asc}) { id } nin: User(where: {updatesCountOnUserForTesting: {_nin: [0, 7, 2147483647]}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-int-is-null",
    query: `{ isNull: EntityWithAllNonArrayTypes(where: {optInt: {_is_null: true}}, order_by: {id: asc}) { id } notNull: EntityWithAllNonArrayTypes(where: {optInt: {_is_null: false}}, order_by: {id: asc}) { id optInt } }`,
  },
  {
    name: "wm-int-eq-int32-max",
    query: `{ User(where: {updatesCountOnUserForTesting: {_eq: 2147483647}}, order_by: {id: asc}) { id updatesCountOnUserForTesting } }`,
  },
  {
    name: "wm-int-eq-int32-min",
    query: `{ User(where: {updatesCountOnUserForTesting: {_eq: -2147483648}}, order_by: {id: asc}) { id updatesCountOnUserForTesting } }`,
  },

  // ── numeric (Token.tokenId, EntityWithBigDecimal.bigDecimal) ─────────
  {
    name: "wm-numeric-eq-neq-trailing-zero",
    query: `{ eq: EntityWithBigDecimal(where: {bigDecimal: {_eq: "1.1"}}, order_by: {id: asc}) { id bigDecimal } neq: EntityWithBigDecimal(where: {bigDecimal: {_neq: "1.1"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-numeric-gt-gte",
    query: `{ gt: EntityWithBigDecimal(where: {bigDecimal: {_gt: "1.1"}}, order_by: {id: asc}) { id bigDecimal } gte: EntityWithBigDecimal(where: {bigDecimal: {_gte: "1.10"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-numeric-lt-lte",
    query: `{ lt: EntityWithBigDecimal(where: {bigDecimal: {_lt: 0}}, order_by: {id: asc}) { id bigDecimal } lte: EntityWithBigDecimal(where: {bigDecimal: {_lte: 0}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-numeric-in-nin",
    query: `{ in: Token(where: {tokenId: {_in: ["-5", 7, "1000000000000000000000000000000"]}}, order_by: {id: asc}) { id tokenId } nin: Token(where: {tokenId: {_nin: ["-5", 7, "1000000000000000000000000000000"]}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-numeric-is-null",
    query: `{ isNull: EntityWithAllNonArrayTypes(where: {optBigInt: {_is_null: true}}, order_by: {id: asc}) { id } notNull: EntityWithAllNonArrayTypes(where: {optBigInt: {_is_null: false}}, order_by: {id: asc}) { id optBigInt } }`,
  },
  {
    name: "wm-numeric-eq-tiny-fraction",
    query: `{ EntityWithBigDecimal(where: {bigDecimal: {_eq: "0.000000000000000001"}}, order_by: {id: asc}) { id bigDecimal } }`,
  },
  {
    name: "wm-numeric-eq-76-digits",
    query: `{ Token(where: {tokenId: {_eq: "9999999999999999999999999999999999999999999999999999999999999999999999999999"}}, order_by: {id: asc}) { id tokenId } }`,
  },

  // ── float8 (EntityWithAllNonArrayTypes.float_) ───────────────────────
  {
    name: "wm-float-eq-neq",
    query: `{ eq: EntityWithAllNonArrayTypes(where: {float_: {_eq: "-3.14159"}}, order_by: {id: asc}) { id float_ } neq: EntityWithAllNonArrayTypes(where: {float_: {_neq: "-3.14159"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-float-gt-gte-dbl-max",
    query: `{ gt: EntityWithAllNonArrayTypes(where: {float_: {_gt: "1.7976931348623157e308"}}, order_by: {id: asc}) { id float_ } gte: EntityWithAllNonArrayTypes(where: {float_: {_gte: "1.7976931348623157e308"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-float-lt-lte",
    query: `{ lt: EntityWithAllNonArrayTypes(where: {float_: {_lt: "-0.5"}}, order_by: {id: asc}) { id float_ } lte: EntityWithAllNonArrayTypes(where: {float_: {_lte: "-0.5"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-float-in-nin",
    query: `{ in: EntityWithAllNonArrayTypes(where: {float_: {_in: [1.5, "0.1", -0.5]}}, order_by: {id: asc}) { id float_ } nin: EntityWithAllNonArrayTypes(where: {float_: {_nin: [1.5, "0.1", -0.5]}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-float-is-null",
    query: `{ isNull: EntityWithAllNonArrayTypes(where: {optFloat: {_is_null: true}}, order_by: {id: asc}) { id } notNull: EntityWithAllNonArrayTypes(where: {optFloat: {_is_null: false}}, order_by: {id: asc}) { id optFloat } }`,
  },
  {
    name: "wm-float-eq-infinity-literal",
    query: `{ EntityWithAllNonArrayTypes(where: {float_: {_eq: "Infinity"}}, order_by: {id: asc}) { id float_ } }`,
  },
  {
    name: "wm-float-eq-zero-matches-neg-zero",
    query: `{ EntityWithAllNonArrayTypes(where: {optFloat: {_eq: 0}}, order_by: {id: asc}) { id optFloat } }`,
  },
  {
    name: "wm-float-eq-nan",
    query: `{ EntityWithAllNonArrayTypes(where: {optFloat: {_eq: "NaN"}}, order_by: {id: asc}) { id optFloat } }`,
  },

  // ── boolean (EntityWithAllNonArrayTypes.bool) ────────────────────────
  {
    name: "wm-bool-eq-neq",
    query: `{ eq: EntityWithAllNonArrayTypes(where: {bool: {_eq: false}}, order_by: {id: asc}) { id bool } neq: EntityWithAllNonArrayTypes(where: {bool: {_neq: false}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-bool-gt-gte",
    query: `{ gt: EntityWithAllNonArrayTypes(where: {bool: {_gt: false}}, order_by: {id: asc}) { id } gte: EntityWithAllNonArrayTypes(where: {bool: {_gte: true}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-bool-lt-lte",
    query: `{ lt: EntityWithAllNonArrayTypes(where: {bool: {_lt: true}}, order_by: {id: asc}) { id } lte: EntityWithAllNonArrayTypes(where: {bool: {_lte: false}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-bool-in-nin",
    query: `{ in: EntityWithAllNonArrayTypes(where: {bool: {_in: [false]}}, order_by: {id: asc}) { id } nin: EntityWithAllNonArrayTypes(where: {bool: {_nin: [false]}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-bool-is-null",
    query: `{ isNull: EntityWithAllNonArrayTypes(where: {optBool: {_is_null: true}}, order_by: {id: asc}) { id } notNull: EntityWithAllNonArrayTypes(where: {optBool: {_is_null: false}}, order_by: {id: asc}) { id optBool } }`,
  },

  // ── timestamptz (EntityWithTimestamp.timestamp) ──────────────────────
  {
    name: "wm-ts-eq-neq",
    query: `{ eq: EntityWithTimestamp(where: {timestamp: {_eq: "2024-01-15T12:34:56.123+00:00"}}, order_by: {id: asc}) { id timestamp } neq: EntityWithTimestamp(where: {timestamp: {_neq: "2024-01-15T12:34:56.123+00:00"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-ts-gt-gte",
    query: `{ gt: EntityWithTimestamp(where: {timestamp: {_gt: "2024-01-15T12:34:56.123456+00:00"}}, order_by: {id: asc}) { id } gte: EntityWithTimestamp(where: {timestamp: {_gte: "2024-01-15T12:34:56.123456+00:00"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-ts-lt-lte",
    query: `{ lt: EntityWithTimestamp(where: {timestamp: {_lt: "1970-01-01T00:00:00+00:00"}}, order_by: {id: asc}) { id timestamp } lte: EntityWithTimestamp(where: {timestamp: {_lte: "1970-01-01T00:00:00+00:00"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-ts-in-nin",
    query: `{ in: EntityWithTimestamp(where: {timestamp: {_in: ["1970-01-01T00:00:00Z", "9999-12-31T23:59:59.999999+00:00"]}}, order_by: {id: asc}) { id } nin: EntityWithTimestamp(where: {timestamp: {_nin: ["1970-01-01T00:00:00Z", "9999-12-31T23:59:59.999999+00:00"]}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-ts-is-null",
    query: `{ isNull: EntityWithAllNonArrayTypes(where: {optTimestamp: {_is_null: true}}, order_by: {id: asc}) { id } notNull: EntityWithAllNonArrayTypes(where: {optTimestamp: {_is_null: false}}, order_by: {id: asc}) { id optTimestamp } }`,
  },
  {
    name: "wm-ts-eq-normalized-offset",
    query: `{ EntityWithTimestamp(where: {timestamp: {_eq: "2024-06-15T02:30:00+00:00"}}, order_by: {id: asc}) { id timestamp } }`,
  },

  // ── enum scalars (User.accountType, Gravatar.size) ───────────────────
  {
    name: "wm-enum-eq-neq",
    query: `{ eq: User(where: {accountType: {_eq: "ADMIN"}}, order_by: {id: asc}) { id accountType } neq: User(where: {accountType: {_neq: "ADMIN"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-enum-gt-gte",
    query: `{ gt: User(where: {accountType: {_gt: "ADMIN"}}, order_by: {id: asc}) { id accountType } gte: User(where: {accountType: {_gte: "ADMIN"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-enum-lt-lte-declaration-order",
    query: `{ lt: Gravatar(where: {size: {_lt: "MEDIUM"}}, order_by: {id: asc}) { id size } lte: Gravatar(where: {size: {_lte: "MEDIUM"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-enum-in-nin",
    query: `{ in: Gravatar(where: {size: {_in: ["SMALL", "LARGE"]}}, order_by: {id: asc}) { id size } nin: Gravatar(where: {size: {_nin: ["SMALL", "LARGE"]}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-enum-is-null",
    query: `{ isNull: EntityWithAllNonArrayTypes(where: {optEnumField: {_is_null: true}}, order_by: {id: asc}) { id } notNull: EntityWithAllNonArrayTypes(where: {optEnumField: {_is_null: false}}, order_by: {id: asc}) { id optEnumField } }`,
  },

  // ── text arrays (EntityWithAllTypes.arrayOfStrings) ──────────────────
  {
    name: "wm-array-eq-neq",
    query: `{ eq: EntityWithAllTypes(where: {arrayOfStrings: {_eq: ["one", "two", "three"]}}, order_by: {id: asc}) { id arrayOfStrings } neq: EntityWithAllTypes(where: {arrayOfStrings: {_neq: ["one", "two", "three"]}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-array-gt-gte",
    query: `{ gt: EntityWithAllTypes(where: {arrayOfStrings: {_gt: ["b"]}}, order_by: {id: asc}) { id arrayOfStrings } gte: EntityWithAllTypes(where: {arrayOfStrings: {_gte: ["b"]}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-array-lt-lte",
    query: `{ lt: EntityWithAllTypes(where: {arrayOfStrings: {_lt: ["b"]}}, order_by: {id: asc}) { id arrayOfStrings } lte: EntityWithAllTypes(where: {arrayOfStrings: {_lte: ["b"]}}, order_by: {id: asc}) { id } }`,
  },
  {
    // Hasura v2.43 generates broken SQL for _in/_nin on array columns and
    // always answers "database query error"; this pins that error shape.
    name: "wm-array-in-database-error",
    query: `{ EntityWithAllTypes(where: {arrayOfStrings: {_in: [["a"], ["one", "two", "three"]]}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-array-is-null",
    query: `{ isNull: EntityWithAllTypes(where: {arrayOfStrings: {_is_null: true}}, order_by: {id: asc}) { id } notNull: EntityWithAllTypes(where: {arrayOfStrings: {_is_null: false}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-array-contains-contained-in",
    query: `{ contains: EntityWithAllTypes(where: {arrayOfStrings: {_contains: ["two"]}}, order_by: {id: asc}) { id arrayOfStrings } containedIn: EntityWithAllTypes(where: {arrayOfStrings: {_contained_in: ["a", "b", "one", "two", "three"]}}, order_by: {id: asc}) { id } }`,
  },

  // ── bigint (raw_events.event_id) ─────────────────────────────────────
  {
    name: "wm-bigint-eq-neq",
    query: `{ eq: raw_events(where: {event_id: {_eq: "4611686018427387905"}}, order_by: {serial: asc}) { serial event_id } neq: raw_events(where: {event_id: {_neq: "4611686018427387905"}}, order_by: {serial: asc}) { serial } }`,
  },
  {
    name: "wm-bigint-gt-gte",
    query: `{ gt: raw_events(where: {event_id: {_gt: "4611686018427387905"}}, order_by: {serial: asc}) { serial event_id } gte: raw_events(where: {event_id: {_gte: "4611686018427387905"}}, order_by: {serial: asc}) { serial } }`,
  },
  {
    name: "wm-bigint-lt-lte-int-literal",
    query: `{ lt: raw_events(where: {event_id: {_lt: 2}}, order_by: {serial: asc}) { serial event_id } lte: raw_events(where: {event_id: {_lte: 2}}, order_by: {serial: asc}) { serial } }`,
  },
  {
    name: "wm-bigint-in-nin-mixed-literals",
    query: `{ in: raw_events(where: {event_id: {_in: [1, "4611686018427387906"]}}, order_by: {serial: asc}) { serial event_id } nin: raw_events(where: {event_id: {_nin: [1, "4611686018427387906"]}}, order_by: {serial: asc}) { serial } }`,
  },
  {
    name: "wm-bigint-is-null",
    query: `{ isNull: raw_events(where: {event_id: {_is_null: true}}, order_by: {serial: asc}) { serial } notNull: raw_events(where: {event_id: {_is_null: false}}, order_by: {serial: asc}) { serial } }`,
  },
  {
    name: "wm-bigint-eq-unquoted-64bit-literal",
    query: `{ raw_events(where: {event_id: {_eq: 4611686018427387904}}, order_by: {serial: asc}) { serial event_id } }`,
  },

  // ── operator edge combinations ───────────────────────────────────────
  {
    name: "wm-in-duplicate-values",
    query: `{ Token(where: {tokenId: {_in: [1, 1, "1", 2]}}, order_by: {id: asc}) { id tokenId } }`,
  },
  {
    name: "wm-in-single-value",
    query: `{ SimpleEntity(where: {value: {_in: ["v7"]}}, order_by: {id: asc}) { id value } }`,
  },
  {
    name: "wm-is-null-false-with-like",
    query: `{ User(where: {gravatar_id: {_is_null: false, _like: "grav-%"}}, order_by: {id: asc}) { id gravatar_id } }`,
  },
  {
    name: "wm-is-null-true-with-eq",
    query: `{ User(where: {gravatar_id: {_is_null: true, _eq: "grav-1"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-jsonb-eq-object-literal",
    query: `{ raw_events(where: {params: {_eq: {from: "0x0", to: "0x1", value: "100"}}}, order_by: {serial: asc}) { serial params } }`,
  },
  {
    name: "wm-jsonb-eq-empty-object",
    query: `{ EntityWithAllTypes(where: {json: {_eq: {}}}, order_by: {id: asc}) { id json } }`,
  },
  {
    name: "wm-jsonb-eq-nested-object",
    query: `{ EntityWithAllTypes(where: {json: {_eq: {kind: "object", n: 1, nested: {a: [1, 2]}}}}, order_by: {id: asc}) { id } }`,
  },
  {
    // _cast casts the jsonb column to text, then applies a
    // String_comparison_exp — a distinct code path (CompareOp::CastText)
    // from every other jsonb operator above.
    name: "wm-jsonb-cast-string-like",
    query: `{ EntityWithAllTypes(where: {json: {_cast: {String: {_like: "%\\"kind\\"%"}}}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "wm-jsonb-cast-string-eq-scalar",
    query: `{ EntityWithAllTypes(where: {json: {_cast: {String: {_eq: "\\"just a string\\""}}}}, order_by: {id: asc}) { id } }`,
  },
]);
