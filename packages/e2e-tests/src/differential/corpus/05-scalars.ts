import { defineCases } from "../corpus.js";

export default defineCases([
  {
    name: "scalars-all-non-array-full",
    query: `{ EntityWithAllNonArrayTypes(order_by: {id: asc}) { id string optString int_ optInt float_ optFloat bool optBool bigInt optBigInt bigDecimal optBigDecimal bigDecimalWithConfig enumField optEnumField timestamp optTimestamp } }`,
    bench: true,
  },
  {
    name: "scalars-all-types-full",
    query: `{ EntityWithAllTypes(order_by: {id: asc}) { id string optString arrayOfStrings int_ optInt arrayOfInts float_ optFloat arrayOfFloats bool optBool bigInt optBigInt arrayOfBigInts bigDecimal optBigDecimal bigDecimalWithConfig arrayOfBigDecimals timestamp optTimestamp json enumField optEnumField } }`,
    bench: true,
  },
  {
    name: "scalars-numeric-precision-monsters",
    query: `{ PostgresNumericPrecisionEntityTester(order_by: {id: asc}) { id exampleBigInt exampleBigIntRequired exampleBigIntArray exampleBigIntArrayRequired exampleBigDecimal exampleBigDecimalRequired exampleBigDecimalArray exampleBigDecimalArrayRequired exampleBigDecimalOtherOrder } }`,
  },
  {
    name: "scalars-float-special-values",
    query: `{ EntityWithAllNonArrayTypes(where: {id: {_in: ["scalar-special-float", "scalar-neg-inf", "scalar-extremes"]}}, order_by: {id: asc}) { id float_ optFloat } }`,
  },
  {
    name: "scalars-bigdecimal-trailing-zeros",
    query: `{ EntityWithBigDecimal(order_by: {id: asc}) { id bigDecimal } }`,
  },
  {
    name: "scalars-timestamp-precision",
    query: `{ EntityWithTimestamp(order_by: {id: asc}) { id timestamp } }`,
  },
  {
    name: "scalars-jsonb-variants",
    query: `{ EntityWithAllTypes(where: {id: {_like: "all-json%"}}, order_by: {id: asc}) { id json } }`,
  },
  {
    name: "scalars-jsonb-path-arg",
    query: `{ EntityWithAllTypes(where: {id: {_eq: "all-1"}}) { id json(path: "$.nested.a") } }`,
  },
  {
    name: "scalars-jsonb-path-index",
    query: `{ EntityWithAllTypes(where: {id: {_eq: "all-array-edge"}}) { id json(path: "$[4].k") } }`,
  },
  {
    name: "scalars-jsonb-path-missing",
    query: `{ EntityWithAllTypes(where: {id: {_eq: "all-1"}}) { id json(path: "$.does.not.exist") } }`,
  },
  {
    name: "scalars-jsonb-contains",
    query: `{ EntityWithAllTypes(where: {json: {_contains: {kind: "object"}}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "scalars-jsonb-contained-in",
    query: `{ EntityWithAllTypes(where: {json: {_contained_in: {kind: "object", n: 1, nested: {a: [1, 2]}, extra: true}}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "scalars-jsonb-has-key",
    query: `{ EntityWithAllTypes(where: {json: {_has_key: "nested"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "scalars-jsonb-has-keys-any",
    query: `{ EntityWithAllTypes(where: {json: {_has_keys_any: ["kind", "héllo"]}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "scalars-jsonb-has-keys-all",
    query: `{ EntityWithAllTypes(where: {json: {_has_keys_all: ["kind", "n"]}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "scalars-string-arrays-escaping",
    query: `{ EntityWithAllTypes(where: {id: {_eq: "all-array-edge"}}) { id arrayOfStrings } }`,
  },
  {
    name: "scalars-empty-arrays",
    query: `{ EntityWithAllTypes(where: {id: {_eq: "all-empty-arrays"}}) { id arrayOfStrings arrayOfInts arrayOfFloats arrayOfBigInts arrayOfBigDecimals } }`,
  },
  {
    name: "scalars-numeric-array-precision",
    query: `{ PostgresNumericPrecisionEntityTester(where: {id: {_eq: "prec-1"}}) { id exampleBigIntArray exampleBigDecimalArray } }`,
  },
  {
    name: "scalars-unicode-strings",
    query: `{ EntityWithAllNonArrayTypes(where: {id: {_in: ["scalar-unicode", "scalar-quotes"]}}, order_by: {id: asc}) { id string optString } }`,
  },
  {
    name: "scalars-where-on-array-column-eq",
    query: `{ EntityWithAllTypes(where: {arrayOfStrings: {_eq: ["one", "two", "three"]}}, order_by: {id: asc}) { id } }`,
  },
]);
