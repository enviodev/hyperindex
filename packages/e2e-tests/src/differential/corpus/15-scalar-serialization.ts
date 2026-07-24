import { defineCases } from "../corpus.js";

// Full column lists in schema order, so each per-row case pins every value of
// that row in isolation.
const nonArrayCols = `id string optString int_ optInt float_ optFloat bool optBool bigInt optBigInt bigDecimal optBigDecimal bigDecimalWithConfig enumField optEnumField timestamp optTimestamp`;
const allTypesCols = `id string optString arrayOfStrings int_ optInt arrayOfInts float_ optFloat arrayOfFloats bool optBool bigInt optBigInt arrayOfBigInts bigDecimal optBigDecimal bigDecimalWithConfig arrayOfBigDecimals timestamp optTimestamp json enumField optEnumField`;
const precisionCols = `id exampleBigInt exampleBigIntRequired exampleBigIntArray exampleBigIntArrayRequired exampleBigDecimal exampleBigDecimalRequired exampleBigDecimalArray exampleBigDecimalArrayRequired exampleBigDecimalOtherOrder`;

const nonArrayRow = (name: string, id: string) => ({
  name,
  query: `{ EntityWithAllNonArrayTypes_by_pk(id: "${id}") { ${nonArrayCols} } }`,
});
const allTypesRow = (name: string, id: string) => ({
  name,
  query: `{ EntityWithAllTypes_by_pk(id: "${id}") { ${allTypesCols} } }`,
});
const precisionRow = (name: string, id: string) => ({
  name,
  query: `{ PostgresNumericPrecisionEntityTester_by_pk(id: "${id}") { ${precisionCols} } }`,
});
const bigDecimalRow = (name: string, id: string) => ({
  name,
  query: `{ EntityWithBigDecimal_by_pk(id: "${id}") { id bigDecimal } }`,
});
const timestampRow = (name: string, id: string) => ({
  name,
  query: `{ EntityWithTimestamp_by_pk(id: "${id}") { id timestamp } }`,
});

export default defineCases([
  nonArrayRow("ss-row-nonarray-scalar-1", "scalar-1"),
  nonArrayRow("ss-row-nonarray-scalar-nulls", "scalar-nulls"),
  nonArrayRow("ss-row-nonarray-scalar-extremes", "scalar-extremes"),
  nonArrayRow("ss-row-nonarray-scalar-special-float", "scalar-special-float"),
  nonArrayRow("ss-row-nonarray-scalar-neg-inf", "scalar-neg-inf"),
  nonArrayRow("ss-row-nonarray-scalar-unicode", "scalar-unicode"),
  nonArrayRow("ss-row-nonarray-scalar-quotes", "scalar-quotes"),
  nonArrayRow("ss-row-nonarray-scalar-empty", "scalar-empty"),
  allTypesRow("ss-row-alltypes-all-1", "all-1"),
  allTypesRow("ss-row-alltypes-all-empty-arrays", "all-empty-arrays"),
  allTypesRow("ss-row-alltypes-all-array-edge", "all-array-edge"),
  allTypesRow("ss-row-alltypes-all-json-string", "all-json-string"),
  allTypesRow("ss-row-alltypes-all-json-number", "all-json-number"),
  allTypesRow("ss-row-alltypes-all-json-null", "all-json-null"),
  allTypesRow("ss-row-alltypes-all-json-unicode", "all-json-unicode"),
  allTypesRow("ss-row-alltypes-all-json-bool", "all-json-bool"),
  precisionRow("ss-row-precision-prec-1", "prec-1"),
  precisionRow("ss-row-precision-prec-nulls", "prec-nulls"),
  precisionRow("ss-row-precision-prec-2", "prec-2"),
  bigDecimalRow("ss-row-bigdecimal-bd-1", "bd-1"),
  bigDecimalRow("ss-row-bigdecimal-bd-2", "bd-2"),
  bigDecimalRow("ss-row-bigdecimal-bd-3", "bd-3"),
  bigDecimalRow("ss-row-bigdecimal-bd-4", "bd-4"),
  bigDecimalRow("ss-row-bigdecimal-bd-5", "bd-5"),
  timestampRow("ss-row-timestamp-ts-epoch", "ts-epoch"),
  timestampRow("ss-row-timestamp-ts-micro", "ts-micro"),
  timestampRow("ss-row-timestamp-ts-milli", "ts-milli"),
  timestampRow("ss-row-timestamp-ts-pre-epoch", "ts-pre-epoch"),
  timestampRow("ss-row-timestamp-ts-future", "ts-future"),
  timestampRow("ss-row-timestamp-ts-zoned", "ts-zoned"),
  {
    // numeric(n,s)[] elements stay raw JSON numbers (trailing zeros intact)
    // even though STRINGIFY_NUMERIC_TYPES turns numeric scalars into strings.
    name: "ss-arrays-numeric-precision-string-vs-number",
    query: `{ PostgresNumericPrecisionEntityTester(order_by: {id: asc}) { id exampleBigInt exampleBigIntArray exampleBigIntArrayRequired exampleBigDecimal exampleBigDecimalArray exampleBigDecimalArrayRequired } }`,
  },
  {
    name: "ss-arrays-alltypes-string-vs-number",
    query: `{ EntityWithAllTypes(order_by: {id: asc}) { id arrayOfInts float_ arrayOfFloats bigInt arrayOfBigInts bigDecimal arrayOfBigDecimals } }`,
  },
  {
    name: "ss-json-path-key",
    query: `{ EntityWithAllTypes_by_pk(id: "all-1") { id json(path: "$.kind") } }`,
  },
  {
    name: "ss-json-path-root-index",
    query: `{ EntityWithAllTypes_by_pk(id: "all-array-edge") { id json(path: "$[0]") } }`,
  },
  {
    name: "ss-json-path-nested-index",
    query: `{ EntityWithAllTypes_by_pk(id: "all-1") { id json(path: "$.nested.a[1]") } }`,
  },
  {
    name: "ss-json-path-missing-nested",
    query: `{ EntityWithAllTypes_by_pk(id: "all-1") { id json(path: "$.nested.missing.deep") } }`,
  },
  {
    name: "ss-json-path-on-scalar-value",
    query: `{ EntityWithAllTypes_by_pk(id: "all-json-string") { id json(path: "$.anything") } }`,
  },
  {
    name: "ss-json-path-on-json-null",
    query: `{ EntityWithAllTypes_by_pk(id: "all-json-null") { id json(path: "$.x") } }`,
  },
  {
    // "$" returns the whole document in jsonb key order, not insertion order.
    name: "ss-json-path-dollar-root",
    query: `{ EntityWithAllTypes_by_pk(id: "all-1") { id json(path: "$") } }`,
  },
  {
    // Hasura accepts paths without the leading "$." prefix.
    name: "ss-json-path-no-dollar-prefix",
    query: `{ EntityWithAllTypes_by_pk(id: "all-1") { id json(path: "kind") } }`,
  },
  {
    name: "ss-json-path-unicode-key",
    query: `{ EntityWithAllTypes_by_pk(id: "all-json-unicode") { id json(path: "$.héllo") } }`,
  },
  {
    name: "ss-json-path-empty-string-error",
    query: `{ EntityWithAllTypes_by_pk(id: "all-1") { id json(path: "") } }`,
  },
  {
    name: "ss-json-path-variable",
    query: `query ($p: String) { EntityWithAllTypes_by_pk(id: "all-1") { id json(path: $p) } }`,
    variables: { p: "$.nested.a" },
  },
  {
    name: "ss-json-alias-three-paths",
    query: `{ EntityWithAllTypes_by_pk(id: "all-1") { id whole: json(path: "$") kind: json(path: "$.kind") second: json(path: "$.nested.a[0]") } }`,
  },
  {
    name: "ss-bypk-special-chars-full",
    query: `{ User_by_pk(id: "user \\"quoted\\" 🚀") { id address gravatar_id updatesCountOnUserForTesting accountType } }`,
  },
  {
    name: "ss-bypk-special-chars-variable",
    query: `query ($id: String!) { User_by_pk(id: $id) { id address accountType } }`,
    variables: { id: 'user "quoted" 🚀' },
  },
  {
    name: "ss-typename-only-list",
    query: `{ EntityWithBigDecimal(order_by: {id: asc}) { __typename } }`,
  },
  {
    name: "ss-typename-only-by-pk",
    query: `{ PostgresNumericPrecisionEntityTester_by_pk(id: "prec-1") { __typename } }`,
  },
  {
    name: "ss-field-order-reverse-schema",
    query: `{ EntityWithAllNonArrayTypes_by_pk(id: "scalar-1") { optTimestamp timestamp optEnumField enumField bigDecimalWithConfig optBigDecimal bigDecimal optBigInt bigInt optBool bool optFloat float_ optInt int_ optString string id } }`,
  },
  {
    name: "ss-field-order-interleaved",
    query: `{ EntityWithAllTypes_by_pk(id: "all-1") { json bool __typename bigDecimal id enumField arrayOfInts } }`,
  },
]);
