import { defineCases } from "../corpus.js";

const deepGravatarOwner = (levels: number): string => {
  let sel = "id";
  for (let i = 0; i < levels; i++) sel = `id gravatar { id owner { ${sel} } }`;
  return sel;
};

export default defineCases([
  // ── arguments of the wrong structural kind ───────────────────────────
  {
    name: "em-arg-where-as-list",
    query: `{ User(where: [{id: {_eq: "user-1"}}]) { id } }`,
  },
  {
    name: "em-arg-where-as-string",
    query: `{ User(where: "id") { id } }`,
  },
  {
    name: "em-arg-order-by-as-enum-literal",
    query: `{ User(order_by: asc) { id } }`,
  },
  {
    name: "em-arg-order-by-as-string",
    query: `{ User(order_by: "asc") { id } }`,
  },
  {
    name: "em-arg-limit-as-object",
    query: `{ User(limit: {value: 5}) { id } }`,
  },
  {
    name: "em-arg-limit-as-list",
    query: `{ User(limit: [1]) { id } }`,
  },
  {
    name: "em-arg-distinct-on-unknown-column",
    query: `{ User(distinct_on: notAColumn) { id } }`,
  },
  // ── unknown fields and args per nesting level ────────────────────────
  {
    name: "em-unknown-field-root-typo",
    query: `{ Userz { id } }`,
  },
  {
    name: "em-unknown-field-object-rel",
    query: `{ User(order_by: {id: asc}, limit: 1) { id gravatar { id bogusField } } }`,
  },
  {
    name: "em-unknown-field-array-rel",
    query: `{ User(order_by: {id: asc}, limit: 1) { id tokens { id bogusField } } }`,
  },
  {
    name: "em-unknown-field-aggregate-wrapper",
    role: "admin",
    query: `{ Token_aggregate { bogus } }`,
  },
  {
    name: "em-unknown-field-aggregate-body",
    role: "admin",
    query: `{ Token_aggregate { aggregate { bogus } } }`,
  },
  {
    name: "em-unknown-arg-aggregate-count",
    role: "admin",
    query: `{ Token_aggregate { aggregate { count(bogus: true) } } }`,
  },
  {
    name: "em-unknown-arg-on-scalar-column",
    query: `{ User(order_by: {id: asc}, limit: 1) { id address(bogus: 1) } }`,
  },
  // ── duplicate names in document syntax ───────────────────────────────
  {
    name: "em-duplicate-argument-name",
    query: `{ User(limit: 1, limit: 2) { id } }`,
  },
  {
    name: "em-duplicate-key-in-input-object",
    query: `{ User(where: {id: {_eq: "user-1", _eq: "user-2"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "em-duplicate-variable-definition",
    query: `query ($l: Int, $l: Int) { User(order_by: {id: asc}, limit: $l) { id } }`,
    variables: { l: 1 },
  },
  // ── malformed string literals ────────────────────────────────────────
  {
    name: "em-string-bad-unicode-escape",
    query: `{ User_by_pk(id: "\\uZZZZ") { id } }`,
  },
  {
    name: "em-string-lone-surrogate-escape",
    query: `{ User_by_pk(id: "\\uD800") { id } }`,
  },
  {
    name: "em-string-unknown-escape",
    query: `{ User_by_pk(id: "\\q") { id } }`,
  },
  {
    // The JSON request body itself carries an unpaired surrogate escape.
    name: "em-body-lone-surrogate-in-query",
    query: `{ User_by_pk(id: "\uD800") { id } }`,
  },
  // ── numeric literal overflow ─────────────────────────────────────────
  {
    name: "em-int-literal-overflow-int32",
    query: `{ User(order_by: {id: asc}, limit: 2147483648) { id } }`,
  },
  {
    name: "em-int-literal-overflow-int64",
    query: `{ User(order_by: {id: asc}, limit: 9223372036854775808) { id } }`,
  },
  {
    name: "em-float-literal-overflow",
    query: `{ EntityWithAllNonArrayTypes(where: {float_: {_lt: 1e400}}, order_by: {id: asc}) { id } }`,
  },
  // ── variable declaration vs usage mismatches ─────────────────────────
  {
    name: "em-var-string-decl-used-as-int",
    query: `query ($l: String!) { User(order_by: {id: asc}, limit: $l) { id } }`,
    variables: { l: "1" },
  },
  {
    name: "em-var-wrong-name-used",
    query: `query ($lim: Int) { User(order_by: {id: asc}, limit: $limit) { id } }`,
    variables: { lim: 1 },
  },
  // ── fragment type conditions ─────────────────────────────────────────
  // Hasura does not reject fragments whose type condition can never match:
  // it silently drops their selections and answers with the rest.
  {
    name: "em-fragment-on-scalar-type",
    query: `fragment F on String { length } { User(order_by: {id: asc}, limit: 1) { ...F } }`,
  },
  {
    name: "em-fragment-on-enum-type",
    query: `fragment F on order_by { x } { User(order_by: {id: asc}, limit: 1) { ...F } }`,
  },
  {
    name: "em-inline-fragment-wrong-type",
    query: `{ User(order_by: {id: asc}, limit: 1) { id ... on Gravatar { id } } }`,
  },
  {
    name: "em-inline-fragment-unknown-type",
    query: `{ User(order_by: {id: asc}, limit: 1) { id ... on Bogus { id } } }`,
  },
  // ── directive location ───────────────────────────────────────────────
  {
    name: "em-directive-skip-on-query-operation",
    query: `query Q @skip(if: true) { SimpleEntity(order_by: {id: asc}, limit: 1) { id } }`,
  },
  // ── by_pk argument shape ─────────────────────────────────────────────
  {
    name: "em-by-pk-extra-unknown-arg",
    query: `{ User_by_pk(id: "user-1", bogus: 1) { id } }`,
  },
  {
    name: "em-by-pk-id-null-literal",
    query: `{ User_by_pk(id: null) { id } }`,
  },
  // ── null literals for nullable args (accepted, not errors) ───────────
  {
    name: "em-null-literal-limit",
    query: `{ SimpleEntity(limit: null, order_by: {id: asc}) { id } }`,
  },
  {
    name: "em-null-literal-where",
    query: `{ SimpleEntity(where: null, order_by: {id: asc}) { id } }`,
  },
  // ── degenerate documents ─────────────────────────────────────────────
  {
    name: "em-empty-selection-braces-field",
    query: `{ User(limit: 1) { } }`,
  },
  {
    name: "em-empty-selection-braces-root",
    query: `{ }`,
  },
  {
    name: "em-comments-only-query",
    query: `# just a comment\n# and another one`,
  },
  {
    name: "em-whitespace-only-query",
    query: `  \n\t  `,
  },
  // ── depth ────────────────────────────────────────────────────────────
  {
    name: "em-deep-nesting-40-levels",
    query: `{ User_by_pk(id: "user-1") { ${deepGravatarOwner(20)} } }`,
  },
  // ── operation kinds over HTTP ────────────────────────────────────────
  {
    name: "em-subscription-multiple-root-fields",
    query: `subscription { User(limit: 1) { id } Gravatar(limit: 1) { id } }`,
  },
  {
    name: "em-unknown-operation-type-keyword",
    query: `queery { User { id } }`,
  },
  // ── request body shape ───────────────────────────────────────────────
  {
    name: "em-opname-empty-string",
    query: `query Q { SimpleEntity(order_by: {id: asc}, limit: 1) { id } }`,
    operationName: "",
  },
]);
