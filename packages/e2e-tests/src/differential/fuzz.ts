/**
 * Schema-driven differential fuzzer: generates random queries from the live
 * introspected schema, runs them against Hasura and `envio serve`, and
 * reports any response that differs.
 *
 * The hand-written corpus covers what someone thought to enumerate. Parity
 * bugs live in the combinations nobody enumerates — a column type crossed
 * with an operator crossed with a malformed operand — which is what this
 * reaches. A finding is shrunk to a minimal query before it is reported, and
 * findings are grouped by shape so one bug reports once however often it is
 * hit.
 *
 * Confirmed findings belong in the corpus (with a recorded snapshot), not
 * here: this finds bugs, the corpus pins them.
 *
 * Two classes of difference are NOT bugs and are deliberately not generated,
 * because both are decided by the iteration order of a Haskell HashMap that
 * cannot be reproduced from outside Hasura:
 *
 * - Which key is blamed when ONE input object holds SEVERAL invalid values.
 *   Hasura's choice is fixed per key set but follows neither document,
 *   alphabetical, nor schema order. Generation therefore spends at most one
 *   ill-typed value per query (`adversarialBudget`), so a reported finding is
 *   always about the value, never about which sibling got blamed first.
 * - Which column wins in a multi-key `order_by` OBJECT (`{a: asc, b: desc}`).
 *   Hasura's precedence there is likewise hash order, and its own docs say to
 *   pass an array of single-key objects for defined multi-column ordering.
 *   Only the array form is generated; it is exact-parity in both engines.
 *
 * Usage (needs Hasura 8080 + envio serve 8081):
 *   pnpm fuzz:differential -- [--seeds 1..20] [--n 500] [--concurrency 8]
 *                             [--phase default|limited] [--admin-ratio 0.3]
 *                             [--verbose]
 *
 * The fixture and Hasura's metadata are (re)applied for the chosen phase
 * before fuzzing, because the two engines must be configured identically for
 * a difference to mean anything: a Hasura still tracked for another phase
 * reports every row-limit and aggregate-visibility difference as a bug.
 * `envio serve` must be started with that phase's environment
 * (ENVIO_HASURA_RESPONSE_LIMIT / ENVIO_HASURA_PUBLIC_AGGREGATE) to match.
 */

import { hasuraUrl, serveUrl, adminSecret } from "./env.js";
import { arg, flag } from "./cliArgs.js";
import { applyFixture, trackDatabase } from "./hasuraSetup.js";
import { phaseConfigs, type Phase } from "./corpus.js";

// ---------------------------------------------------------------------------
// Deterministic RNG — every query is a pure function of its seed, so a
// reported finding replays exactly.

class Rng {
  private state: number;
  constructor(seed: number) {
    this.state = (seed | 0) || 1;
  }
  next(): number {
    // xorshift32: cheap and good enough, and identical across engines
    let x = this.state;
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    this.state = x | 0;
    return ((x >>> 0) % 1_000_000) / 1_000_000;
  }
  pick<T>(xs: readonly T[]): T {
    return xs[Math.floor(this.next() * xs.length)]!;
  }
  chance(p: number): boolean {
    return this.next() < p;
  }
  int(lo: number, hi: number): number {
    return lo + Math.floor(this.next() * (hi - lo + 1));
  }
  sample<T>(xs: readonly T[], min: number, max: number): T[] {
    const pool = [...xs];
    const n = Math.min(pool.length, this.int(min, max));
    const out: T[] = [];
    for (let i = 0; i < n; i++)
      out.push(pool.splice(Math.floor(this.next() * pool.length), 1)[0]!);
    return out;
  }
}

// ---------------------------------------------------------------------------
// Introspected schema

interface TypeRef {
  kind: string;
  name: string | null;
  ofType: TypeRef | null;
}
interface InputField {
  name: string;
  type: TypeRef;
}
interface SchemaField {
  name: string;
  type: TypeRef;
  args: InputField[];
}
interface SchemaType {
  kind: string;
  name: string;
  fields: SchemaField[] | null;
  inputFields: InputField[] | null;
  enumValues: { name: string }[] | null;
}

/** The named type at the bottom of a NON_NULL/LIST chain. */
function baseType(t: TypeRef): { name: string; kind: string } {
  let cur = t;
  while (cur.ofType) cur = cur.ofType;
  return { name: cur.name ?? "", kind: cur.kind };
}

/** Renders a type reference back to GraphQL syntax, e.g. `[Int!]!`. */
function renderType(t: TypeRef): string {
  if (t.kind === "NON_NULL") return `${renderType(t.ofType!)}!`;
  if (t.kind === "LIST") return `[${renderType(t.ofType!)}]`;
  return t.name ?? "String";
}

/** Whether a type is a list at any wrapping level. */
function isListType(t: TypeRef): boolean {
  let cur: TypeRef | null = t;
  while (cur) {
    if (cur.kind === "LIST") return true;
    cur = cur.ofType;
  }
  return false;
}

const INTROSPECTION = `{ __schema { queryType { name } types {
  kind name
  fields { name type { ...T } args { name type { ...T } } }
  inputFields { name type { ...T } }
  enumValues { name }
} } }
fragment T on __Type { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name } } } } }`;

class Schema {
  types = new Map<string, SchemaType>();
  roots: SchemaField[] = [];

  static async load(url: string): Promise<Schema> {
    const res = await post(url, INTROSPECTION, true);
    const parsed = JSON.parse(res.body);
    if (!parsed.data) throw new Error(`introspection failed: ${res.body.slice(0, 300)}`);
    const s = new Schema();
    for (const t of parsed.data.__schema.types as SchemaType[]) s.types.set(t.name, t);
    const rootName = parsed.data.__schema.queryType.name as string;
    s.roots = (s.types.get(rootName)?.fields ?? []).filter(
      (f) => !f.name.startsWith("__")
    );
    return s;
  }

  /** Scalar/enum leaf fields of an output object type. */
  scalarFields(typeName: string): SchemaField[] {
    return (this.types.get(typeName)?.fields ?? []).filter((f) => {
      const b = baseType(f.type);
      return b.kind === "SCALAR" || b.kind === "ENUM";
    });
  }

  objectFields(typeName: string): SchemaField[] {
    return (this.types.get(typeName)?.fields ?? []).filter(
      (f) => baseType(f.type).kind === "OBJECT"
    );
  }

  inputFields(typeName: string): InputField[] {
    return this.types.get(typeName)?.inputFields ?? [];
  }
}

// ---------------------------------------------------------------------------
// Query AST — structured so a failing query can be shrunk mechanically.

interface Node {
  field: string;
  alias?: string;
  args: [string, string][];
  children: Node[];
  /** e.g. `@include(if: true)` — rendered verbatim after the arguments. */
  directive?: string;
  /** Wraps the children in `... on <type> { }`. */
  inlineFragmentOn?: string;
  /** Replaces the children with a spread of these named fragments. */
  fragmentSpreads?: string[];
}

function render(node: Node, indent = ""): string {
  const args = node.args.length
    ? `(${node.args.map(([k, v]) => `${k}: ${v}`).join(", ")})`
    : "";
  const name = node.alias ? `${node.alias}: ${node.field}` : node.field;
  const dir = node.directive ? ` ${node.directive}` : "";
  if (!node.children.length && !node.fragmentSpreads?.length)
    return `${indent}${name}${args}${dir}`;
  const spreads = (node.fragmentSpreads ?? []).map((f) => `${indent}  ...${f}`);
  const rendered = node.children.map((c) => render(c, indent + "  "));
  const body = [...rendered, ...spreads].join("\n");
  const inner = node.inlineFragmentOn
    ? `${indent}  ... on ${node.inlineFragmentOn} {\n${body
        .split("\n")
        .map((l) => `  ${l}`)
        .join("\n")}\n${indent}  }`
    : body;
  return `${indent}${name}${args}${dir} {\n${inner}\n${indent}}`;
}

interface Document {
  query: string;
  variables?: string;
}

/**
 * Assembles the document. Shrinking removes the arguments and selections that
 * referenced a variable or spread a fragment, and GraphQL rejects a document
 * that declares either without using it — so both sets are filtered down to
 * what the rendered body still mentions.
 */
function renderQuery(roots: Node[], opts?: GenOptions): Document {
  const body = `{\n${roots.map((r) => render(r, "  ")).join("\n")}\n}`;
  const used = (name: string, prefix: string) =>
    new RegExp(`\\${prefix}${name}\\b`).test(body);
  const frags = (opts?.fragments ?? []).filter((f) => used(f.name, "."));
  const withFragments = body + frags.map((f) => `\n\nfragment ${f.name} on ${f.onType} {\n${f.body}\n}`).join("");
  const vars = (opts?.variables ?? []).filter((v) =>
    new RegExp(`\\$${v.name}\\b`).test(withFragments)
  );
  const header = vars.length
    ? `query Q(${vars.map((v) => `$${v.name}: ${v.type}`).join(", ")}) `
    : frags.length
      ? "query Q "
      : "";
  return {
    query: `${header}${withFragments}`,
    variables: vars.length
      ? `{${vars.map((v) => `${JSON.stringify(v.name)}:${v.json}`).join(",")}}`
      : undefined,
  };
}

// ---------------------------------------------------------------------------
// Value generation

const ORDER_BY = [
  "asc",
  "desc",
  "asc_nulls_first",
  "asc_nulls_last",
  "desc_nulls_first",
  "desc_nulls_last",
];

/** Literals that are well-typed for a scalar, plus adversarial ones. */
function scalarLiteral(rng: Rng, typeName: string, wellTyped: boolean): string {
  const numeric = ["0", "1", "-1", "42", "9223372036854775807", "1e3", "0.5", "-0.0"];
  const bigNumeric = [...numeric, "99999999999999999999999999", "1e400"];
  const strings = [
    '"user-1"',
    '"tok-1"',
    '""',
    '"nope"',
    '"user \\"quoted\\" 🚀"',
    '"%"',
    '"_"',
    '"\\\\"',
  ];
  const adversarial = [
    "null",
    "true",
    "[]",
    "[1]",
    '["a"]',
    "{}",
    '"not-a-number"',
    "1",
  ];
  if (!wellTyped) return rng.pick(adversarial);
  switch (typeName) {
    case "Int":
      return rng.pick(numeric.slice(0, 5));
    case "Float":
    case "float8":
      return rng.pick(numeric);
    case "numeric":
    case "bigint":
      return rng.pick(bigNumeric);
    case "Boolean":
      return rng.pick(["true", "false"]);
    case "jsonb":
    case "json":
      return rng.pick(['{"a": 1}', "[1, 2]", '"str"', "1", "null"]);
    case "timestamptz":
    case "timestamp":
      return rng.pick(['"2020-01-01T00:00:00Z"', '"2020-01-01"', '"bad-date"']);
    default:
      return rng.pick(strings);
  }
}

/** A literal for an input type, honouring list wrapping. */
function inputLiteral(
  rng: Rng,
  schema: Schema,
  type: TypeRef,
  wellTyped: boolean,
  depth = 0
): string {
  const base = baseType(type);
  const list = isListType(type);
  if (base.kind === "ENUM") {
    const values = schema.types.get(base.name)?.enumValues ?? [];
    const one = values.length ? rng.pick(values).name : "asc";
    return list && rng.chance(0.7) ? `[${one}]` : one;
  }
  if (base.kind === "INPUT_OBJECT" && depth < 2) {
    const fields = schema.inputFields(base.name);
    if (!fields.length) return "{}";
    // One field per input object. Two operators in one comparison object
    // (`{_like: ..., _in: ...}`) reopen the blame-order ambiguity, and do so
    // even when both are well-typed, because Postgres then evaluates two
    // predicates whose runtime errors surface in engine-specific order.
    const chosen = rng.sample(fields, 1, 1);
    const body = chosen
      .map((f) => `${f.name}: ${inputLiteral(rng, schema, f.type, wellTyped, depth + 1)}`)
      .join(", ");
    const obj = `{${body}}`;
    return list && rng.chance(0.7) ? `[${obj}]` : obj;
  }
  const scalar = scalarLiteral(rng, base.name, wellTyped);
  if (!list) return scalar;
  // A list position gets a real list most of the time; the rest of the time a
  // bare scalar, which is exactly where engines disagree about coercion.
  if (rng.chance(0.75))
    return `[${Array.from({ length: rng.int(1, 2) }, () => scalarLiteral(rng, base.name, wellTyped)).join(", ")}]`;
  return scalar;
}

// ---------------------------------------------------------------------------
// Generation

interface GenOptions {
  wellTypedRatio: number;
  maxDepth: number;
  /** Ill-typed values left to spend in the current query. */
  adversarialBudget: number;
  /** Collected while generating one query; empty for a plain literal query. */
  variables?: { name: string; type: string; json: string }[];
  fragments?: { name: string; onType: string; body: string }[];
}

/**
 * Lifts an argument value out into a query variable, which reaches serve as
 * JSON through an entirely different path than an inline literal (variable
 * coercion, number-precision preservation, null handling). Only literals that
 * are already valid JSON are lifted: GraphQL enum literals and input-object
 * keys are unquoted, so they have no direct JSON spelling.
 */
function maybeVariable(
  rng: Rng,
  opts: GenOptions,
  type: TypeRef,
  literal: string
): string {
  if (!opts.variables || !rng.chance(0.25)) return literal;
  try {
    JSON.parse(literal);
  } catch {
    return literal;
  }
  const name = `v${opts.variables.length}`;
  opts.variables.push({ name, type: renderType(type), json: literal });
  return `$${name}`;
}

/**
 * Decides whether this value may be ill-typed, spending from the query's
 * budget. Keeping the budget at one means a mismatch is never about which of
 * several bad siblings Hasura happened to blame first.
 */
function allowAdversarial(rng: Rng, opts: GenOptions): boolean {
  if (opts.adversarialBudget <= 0) return true;
  if (rng.chance(opts.wellTypedRatio)) return true;
  opts.adversarialBudget -= 1;
  return false;
}

/**
 * `<table>_aggregate_fields` holds count plus the typed aggregate groups
 * (sum/avg/max/min/stddev/variance), each over the columns its type allows.
 * These are a serialization surface of their own — a sum over bigint is
 * stringified, a stddev over int is a float — and nothing else in the
 * generator reaches them.
 */
function genAggregateSelection(
  rng: Rng,
  schema: Schema,
  typeName: string,
  opts: GenOptions
): Node[] {
  const out: Node[] = [];
  const fields = schema.types.get(typeName)?.fields ?? [];
  const count = fields.find((f) => f.name === "count");
  if (count && rng.chance(0.6)) {
    const args: [string, string][] = [];
    if (rng.chance(0.3)) args.push(["distinct", rng.pick(["true", "false"])]);
    out.push({ field: "count", args, children: [] });
  }
  const groups = fields.filter((f) => baseType(f.type).kind === "OBJECT");
  for (const group of rng.sample(groups, 1, 2)) {
    const inner = baseType(group.type).name;
    const cols = schema.scalarFields(inner);
    if (!cols.length) continue;
    out.push({
      field: group.name,
      args: [],
      children: rng
        .sample(cols, 1, Math.min(3, cols.length))
        .map((c) => ({ field: c.name, args: [], children: [] })),
    });
  }
  if (!out.length || rng.chance(0.1))
    out.push({ field: "__typename", args: [], children: [] });
  return out;
}

function genSelection(
  rng: Rng,
  schema: Schema,
  typeName: string,
  depth: number,
  opts: GenOptions
): Node[] {
  // An aggregate result object: `aggregate { ... }` and `nodes { ... }`.
  if (typeName.endsWith("_aggregate_fields"))
    return genAggregateSelection(rng, schema, typeName, opts);

  const scalars = schema.scalarFields(typeName);
  const out: Node[] = rng
    .sample(scalars, 1, Math.min(4, scalars.length))
    .map((f) => ({ field: f.name, args: [], children: [] }));

  if (depth < opts.maxDepth && rng.chance(0.4)) {
    const objects = schema.objectFields(typeName);
    if (objects.length) {
      const f = rng.pick(objects);
      const inner = baseType(f.type).name;
      const children = genSelection(rng, schema, inner, depth + 1, opts);
      if (children.length)
        out.push(
          wrapInFragment(rng, opts, inner, {
            field: f.name,
            args: genArgs(rng, schema, f, inner, opts),
            children,
          })
        );
    }
  }
  if (rng.chance(0.12))
    out.push({ field: "__typename", args: [], children: [] });
  // Only when something else survives: a directive that empties an aggregate
  // selection makes Hasura emit a degenerate statement, which is a divergence
  // the corpus already pins (corpus/21-degenerate-aggregates.ts).
  if (rng.chance(0.12) && out.length > 1) {
    const which = rng.int(0, out.length - 1);
    out[which] = {
      ...out[which]!,
      directive: `@${rng.pick(["include", "skip"])}(if: ${rng.pick(["true", "false"])})`,
    };
  }
  if (rng.chance(0.1) && out.length)
    out[0] = { ...out[0]!, alias: `a${rng.int(0, 99)}` };
  return out;
}

/**
 * Sometimes moves a node's selection into a named fragment, or wraps it in an
 * inline fragment on its own type. Both are pure restructurings — the
 * response must not change — which is exactly what makes them worth
 * generating: they exercise a whole resolution path (fragments.rs) that
 * literal selections never reach.
 */
function wrapInFragment(
  rng: Rng,
  opts: GenOptions,
  onType: string,
  node: Node
): Node {
  if (!node.children.length) return node;
  if (opts.fragments && rng.chance(0.15)) {
    const name = `F${opts.fragments.length}`;
    opts.fragments.push({
      name,
      onType,
      body: node.children.map((c) => render(c, "  ")).join("\n"),
    });
    return { ...node, children: [], fragmentSpreads: [name] };
  }
  if (rng.chance(0.12)) return { ...node, inlineFragmentOn: onType };
  return node;
}

function genArgs(
  rng: Rng,
  schema: Schema,
  field: SchemaField,
  returnedType: string,
  opts: GenOptions
): [string, string][] {
  const args: [string, string][] = [];
  const byName = new Map(field.args.map((a) => [a.name, a]));

  if (byName.has("limit") && rng.chance(0.6)) {
    const limit = String(rng.int(0, 5));
    args.push([
      "limit",
      maybeVariable(rng, opts, byName.get("limit")!.type, limit),
    ]);
  }
  if (byName.has("offset") && rng.chance(0.25))
    args.push(["offset", String(rng.int(0, 3))]);
  if (byName.has("order_by") && rng.chance(0.5)) {
    const cols = schema.scalarFields(returnedType);
    if (cols.length) {
      // One key per object: precedence between keys of the SAME object is
      // hash order in Hasura and not reproducible, so only the array form
      // (which is the documented way to order by several columns) is used.
      const picked = rng.sample(cols, 1, 2);
      const objects = picked.map((c) => `{${c.name}: ${rng.pick(ORDER_BY)}}`);
      args.push([
        "order_by",
        objects.length === 1 && rng.chance(0.5)
          ? objects[0]!
          : `[${objects.join(", ")}]`,
      ]);
    }
  }
  if (byName.has("distinct_on") && rng.chance(0.15)) {
    const cols = schema.scalarFields(returnedType);
    if (cols.length) args.push(["distinct_on", rng.pick(cols).name]);
  }
  if (byName.has("where") && rng.chance(0.55)) {
    const w = genWhere(rng, schema, byName.get("where")!, 0, opts);
    if (w) args.push(["where", w]);
  }
  // Required args (by_pk keys) have to be present for the query to be valid.
  for (const a of field.args) {
    if (a.type.kind !== "NON_NULL") continue;
    if (["limit", "offset", "order_by", "where", "distinct_on"].includes(a.name))
      continue;
    const literal = inputLiteral(rng, schema, a.type, allowAdversarial(rng, opts));
    args.push([a.name, maybeVariable(rng, opts, a.type, literal)]);
  }
  return args;
}

function genWhere(
  rng: Rng,
  schema: Schema,
  whereArg: InputField,
  depth: number,
  opts: GenOptions
): string | null {
  const typeName = baseType(whereArg.type).name;
  const fields = schema.inputFields(typeName);
  if (!fields.length) return null;

  // Boolean combinators, sometimes, so nesting gets exercised.
  if (depth < 2 && rng.chance(0.2)) {
    const op = rng.pick(["_and", "_or", "_not"]);
    const inner = genWhere(rng, schema, whereArg, depth + 1, opts);
    if (!inner) return null;
    if (op === "_not") return `{_not: ${inner}}`;
    const second = genWhere(rng, schema, whereArg, depth + 1, opts);
    return `{${op}: [${inner}${second ? `, ${second}` : ""}]}`;
  }

  const col = rng.pick(fields.filter((f) => !f.name.startsWith("_")) ?? fields);
  if (!col) return null;
  const cmpType = baseType(col.type).name;
  const ops = schema.inputFields(cmpType);
  if (!ops.length) {
    // A relationship predicate: recurse into the related table's bool_exp.
    if (depth < 2) {
      const nested = genWhere(rng, schema, col, depth + 1, opts);
      return nested ? `{${col.name}: ${nested}}` : null;
    }
    return null;
  }
  const op = rng.pick(ops);
  const wellTyped = allowAdversarial(rng, opts);
  const literal = inputLiteral(rng, schema, op.type, wellTyped);
  return `{${col.name}: {${op.name}: ${maybeVariable(rng, opts, op.type, literal)}}}`;
}

function generate(rng: Rng, schema: Schema, opts: GenOptions): Node[] {
  const count = rng.chance(0.15) ? 2 : 1;
  const roots: Node[] = [];
  for (let i = 0; i < count; i++) {
    const root = rng.pick(schema.roots);
    const returned = baseType(root.type);
    const children =
      returned.kind === "OBJECT"
        ? genSelection(rng, schema, returned.name, 0, opts)
        : [];
    roots.push(
      wrapInFragment(rng, opts, returned.name, {
        field: root.name,
        alias: count > 1 ? `r${i}` : undefined,
        args: genArgs(rng, schema, root, returned.name, opts),
        children: children.length
          ? children
          : [{ field: "__typename", args: [], children: [] }],
      })
    );
  }
  return roots;
}

// ---------------------------------------------------------------------------
// Execution and comparison

interface Response {
  status: number;
  body: string;
}

async function post(
  url: string,
  query: string,
  admin: boolean,
  variables?: string
): Promise<Response> {
  const res = await fetch(`${url}${url.endsWith("/v1/graphql") ? "" : "/v1/graphql"}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(admin ? { "x-hasura-admin-secret": adminSecret } : {}),
    },
    // Assembled by hand so a generated variables payload keeps its exact
    // JSON text, numeric precision included.
    body: `{"query":${JSON.stringify(query)}${variables ? `,"variables":${variables}` : ""}}`,
  });
  return { status: res.status, body: await res.text() };
}

function canonical(body: string): string {
  try {
    return JSON.stringify(sortDeep(stripInternal(JSON.parse(body))));
  } catch {
    return body;
  }
}

/**
 * `extensions.internal` carries the failing SQL, its parameters and the raw
 * Postgres error. Hasura includes it for the admin role; serve never does,
 * deliberately, so that a compromised admin secret cannot be used to read the
 * generated SQL back out of the API. It is dropped before comparing rather
 * than reported on every admin-role internal error.
 */
function stripInternal(body: unknown): unknown {
  const errors = (body as { errors?: { extensions?: Record<string, unknown> }[] })?.errors;
  if (Array.isArray(errors))
    for (const e of errors) if (e?.extensions) delete e.extensions.internal;
  return body;
}

/**
 * Arrays under data.* are compared as multisets: a generated query rarely has
 * a fully deterministic order_by, and row order without one is not part of
 * the parity contract (the corpus makes the same allowance via "rootSet").
 */
function sortDeep(value: unknown): unknown {
  if (Array.isArray(value)) {
    const mapped = value.map(sortDeep);
    return mapped
      .map((v) => [JSON.stringify(v), v] as const)
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
      .map(([, v]) => v);
  }
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const k of Object.keys(value as object).sort())
      out[k] = sortDeep((value as Record<string, unknown>)[k]);
    return out;
  }
  return value;
}

async function differs(
  doc: Document,
  admin: boolean
): Promise<{ hasura: Response; serve: Response } | null> {
  const [hasura, serve] = await Promise.all([
    post(hasuraUrl, doc.query, admin, doc.variables),
    post(serveUrl, doc.query, admin, doc.variables),
  ]);
  if (hasura.status === serve.status && canonical(hasura.body) === canonical(serve.body))
    return null;
  return { hasura, serve };
}

// ---------------------------------------------------------------------------
// Shrinking — a finding is only useful if it is small enough to read.

/** Every one-step simplification of a query tree. */
function reductions(roots: Node[]): Node[][] {
  const out: Node[][] = [];
  // Drop a whole root (when more than one).
  if (roots.length > 1)
    for (let i = 0; i < roots.length; i++)
      out.push(roots.filter((_, j) => j !== i));

  const walk = (node: Node, rebuild: (n: Node) => Node[]) => {
    // Drop each argument.
    for (let i = 0; i < node.args.length; i++)
      out.push(rebuild({ ...node, args: node.args.filter((_, j) => j !== i) }));
    // Drop each child (keeping at least one).
    if (node.children.length > 1)
      for (let i = 0; i < node.children.length; i++)
        out.push(
          rebuild({ ...node, children: node.children.filter((_, j) => j !== i) })
        );
    // Replace children with __typename only.
    if (
      node.children.length &&
      !(node.children.length === 1 && node.children[0]!.field === "__typename")
    )
      out.push(
        rebuild({
          ...node,
          children: [{ field: "__typename", args: [], children: [] }],
        })
      );
    // Drop an alias, a directive, or an inline-fragment wrapper.
    if (node.alias) out.push(rebuild({ ...node, alias: undefined }));
    if (node.directive) out.push(rebuild({ ...node, directive: undefined }));
    if (node.inlineFragmentOn)
      out.push(rebuild({ ...node, inlineFragmentOn: undefined }));
    // Recurse.
    node.children.forEach((child, i) =>
      walk(child, (n) =>
        rebuild({
          ...node,
          children: node.children.map((c, j) => (j === i ? n : c)),
        })
      )
    );
  };
  roots.forEach((root, i) =>
    walk(root, (n) => roots.map((r, j) => (j === i ? n : r)))
  );
  return out;
}

async function shrink(roots: Node[], admin: boolean, opts: GenOptions): Promise<Node[]> {
  let current = roots;
  let improved = true;
  let budget = 300;
  while (improved && budget > 0) {
    improved = false;
    for (const candidate of reductions(current)) {
      if (budget-- <= 0) break;
      const d = await differs(renderQuery(candidate, opts), admin);
      const known =
        d && KNOWN_DIVERGENCES.some((k) => k.matches(d.hasura.body, d.serve.body));
      if (d && !known && !isBlameOrder(d.hasura, d.serve)) {
        current = candidate;
        improved = true;
        break;
      }
    }
  }
  return current;
}

// ---------------------------------------------------------------------------
// Finding grouping — one bug should report once, not once per hit.

/**
 * Differences that are Hasura bugs serve deliberately does not reproduce.
 * Each is pinned by a corpus case carrying the same explanation, so this list
 * only keeps them out of the fuzzer's actionable output.
 */
const KNOWN_DIVERGENCES: { reason: string; matches: (h: string, s: string) => boolean }[] = [
  {
    reason:
      "jsonb _in/_nin: Hasura binary-encodes non-string elements (buildArrayLiteral " +
      "via PE.jsonb_ast) and Postgres rejects the array literal",
    matches: (h, s) =>
      h.includes("invalid input syntax for type json") &&
      !s.includes("invalid input syntax for type json"),
  },
  {
    reason:
      "aggregate selection with no aggregate function: Hasura's statement returns one " +
      "row per matching row and fails its exactly-one-row assertion",
    matches: (h, s) =>
      h.includes("database query error") && !s.includes("database query error"),
  },
  {
    reason:
      "runtime error visibility: Postgres reorders AND clauses by cost, and Hasura's " +
      "inlined constants let it skip a failing predicate that serve's bound parameters " +
      "leave in place",
    matches: (h, s) =>
      h.includes('"data"') &&
      /"code":"(data-exception|bad-request)"/.test(s),
  },
];

/**
 * A query can hold more than one invalid spot, and the engines then disagree
 * only about which to blame — the unreproducible hash-order class described
 * at the top of this file. Both erroring at DIFFERENT paths is exactly that
 * shape; anything else (one side returning data, or both blaming the same
 * path with a different message or code) is a real difference.
 */
function isBlameOrder(hasura: Response, serve: Response): boolean {
  const errorPath = (r: Response): string | null => {
    try {
      const first = JSON.parse(r.body)?.errors?.[0];
      return first ? String(first.extensions?.path ?? "") : null;
    } catch {
      return null;
    }
  };
  const h = errorPath(hasura);
  const s = errorPath(serve);
  return h !== null && s !== null && h !== s;
}

function signature(hasura: Response, serve: Response): string {
  const shape = (r: Response) => {
    try {
      const parsed = JSON.parse(r.body);
      if (parsed?.errors?.[0])
        return `${parsed.errors[0].extensions?.code ?? "?"}:${String(
          parsed.errors[0].message
        )
          .replace(/'[^']*'/g, "'_'")
          .replace(/"[^"]*"/g, '"_"')
          .slice(0, 80)}`;
      return "data";
    } catch {
      return `raw:${r.status}`;
    }
  };
  return `${shape(hasura)} -vs- ${shape(serve)}`;
}

/**
 * A root-field set that differs between the engines means they are
 * configured differently (or serve's schema build is wrong), and every
 * subsequent finding would be noise. Fail loudly instead.
 */
async function assertSameSchemaShape(): Promise<void> {
  const roots = async (url: string) => {
    const res = await post(url, `{ __type(name: "query_root") { fields { name } } }`, false);
    const parsed = JSON.parse(res.body);
    return (parsed.data?.__type?.fields ?? []).map((f: { name: string }) => f.name).sort();
  };
  const [h, s] = await Promise.all([roots(hasuraUrl), roots(serveUrl)]);
  const onlyHasura = h.filter((n: string) => !s.includes(n));
  const onlyServe = s.filter((n: string) => !h.includes(n));
  if (onlyHasura.length || onlyServe.length) {
    console.error(
      `query_root differs — the engines are not configured alike.\n` +
        `  only in hasura: ${onlyHasura.join(", ") || "(none)"}\n` +
        `  only in serve : ${onlyServe.join(", ") || "(none)"}\n` +
        `Start serve with this phase's ENVIO_HASURA_* environment.`
    );
    process.exit(1);
  }
}

// ---------------------------------------------------------------------------

interface Finding {
  seed: number;
  index: number;
  query: string;
  variables?: string;
  admin: boolean;
  hasura: string;
  serve: string;
}

async function main() {
  const seedsArg = arg("--seeds") ?? "1..8";
  const [seedLo, seedHi] = seedsArg.includes("..")
    ? seedsArg.split("..").map(Number)
    : [Number(seedsArg), Number(seedsArg)];
  const perSeed = Number(arg("--n") ?? 400);
  const concurrency = Number(arg("--concurrency") ?? 8);
  const wellTypedRatio = Number(arg("--well-typed-ratio") ?? 0.75);
  const adminRatio = Number(arg("--admin-ratio") ?? 0.3);
  const verbose = flag("--verbose");

  const phase = (arg("--phase") ?? "default") as Phase;
  const fixtureDir = new URL("../../fixtures/differential/", import.meta.url);
  await applyFixture(fixtureDir);
  await trackDatabase(phaseConfigs[phase]);

  const schema = await Schema.load(serveUrl);
  console.log(
    `fuzzing ${schema.roots.length} root fields, phase ${phase}, seeds ${seedLo}..${seedHi} x ${perSeed}`
  );
  await assertSameSchemaShape();

  const opts: GenOptions = { wellTypedRatio, maxDepth: 2, adversarialBudget: 1 };
  const bySignature = new Map<string, Finding>();
  let checked = 0;
  let hits = 0;
  let ambiguous = 0;
  const divergences = new Map<string, number>();
  // A generator feature that silently stops firing would turn into a quiet
  // loss of coverage, so every run reports what it actually produced.
  const produced = { variables: 0, fragments: 0, inlineFragments: 0, directives: 0, aggregates: 0 };

  for (let seed = seedLo!; seed <= seedHi!; seed++) {
    const rng = new Rng(seed);
    // Generate the whole seed's batch up front so query N depends only on the
    // seed, never on how requests interleaved.
    const batch = Array.from({ length: perSeed }, (_, index) => {
      const perQuery: GenOptions = {
        ...opts,
        adversarialBudget: 1,
        variables: [],
        fragments: [],
      };
      return {
        index,
        roots: generate(rng, schema, perQuery),
        perQuery,
        admin: rng.chance(adminRatio),
      };
    });

    let cursor = 0;
    await Promise.all(
      Array.from({ length: concurrency }, async () => {
        while (cursor < batch.length) {
          const item = batch[cursor++]!;
          const doc = renderQuery(item.roots, item.perQuery);
          if (doc.variables) produced.variables++;
          if (/\bfragment \w+ on /.test(doc.query)) produced.fragments++;
          if (/\.\.\. on /.test(doc.query)) produced.inlineFragments++;
          if (/@(include|skip)\(/.test(doc.query)) produced.directives++;
          if (/_aggregate\b/.test(doc.query)) produced.aggregates++;
          let diff;
          try {
            diff = await differs(doc, item.admin);
          } catch (err) {
            console.error(`request failed: ${err}`);
            continue;
          }
          checked++;
          if (!diff) continue;
          if (isBlameOrder(diff.hasura, diff.serve)) {
            ambiguous++;
            continue;
          }
          const divergence = KNOWN_DIVERGENCES.find((d) =>
            d.matches(diff!.hasura.body, diff!.serve.body)
          );
          if (divergence) {
            divergences.set(divergence.reason, (divergences.get(divergence.reason) ?? 0) + 1);
            continue;
          }
          hits++;
          const sig = signature(diff.hasura, diff.serve);
          if (bySignature.has(sig)) continue;
          // Placeholder first so concurrent workers don't shrink duplicates.
          bySignature.set(sig, {
            seed,
            index: item.index,
            query: doc.query,
            variables: doc.variables,
            admin: item.admin,
            hasura: diff.hasura.body,
            serve: diff.serve.body,
          });
          const small = await shrink(item.roots, item.admin, item.perQuery);
          const smallDoc = renderQuery(small, item.perQuery);
          const reDiff = await differs(smallDoc, item.admin);
          if (reDiff)
            bySignature.set(sig, {
              seed,
              index: item.index,
              query: smallDoc.query,
              variables: smallDoc.variables,
              admin: item.admin,
              hasura: reDiff.hasura.body,
              serve: reDiff.serve.body,
            });
        }
      })
    );
    if (verbose) console.log(`  seed ${seed}: ${checked} checked, ${hits} hits`);
  }

  const findings = [...bySignature.values()];
  console.log(
    `\nchecked ${checked}, actionable mismatches ${hits} in ${findings.length} shapes` +
      `, ${ambiguous} ambiguous (multiple invalid spots, blame order not reproducible)`
  );
  console.log(
    `  generated: ${produced.variables} with variables, ${produced.fragments} with named ` +
      `fragments, ${produced.inlineFragments} inline, ${produced.directives} with directives, ` +
      `${produced.aggregates} aggregate`
  );
  for (const [reason, count] of divergences)
    console.log(`  known divergence x${count}: ${reason}`);
  for (const f of findings) {
    console.log(
      `\n--- seed ${f.seed} #${f.index}${f.admin ? " (admin)" : ""}\n${f.query}` +
        (f.variables ? `\nvariables: ${f.variables}` : "")
    );
    console.log(`  hasura: ${f.hasura.slice(0, 300)}`);
    console.log(`  serve : ${f.serve.slice(0, 300)}`);
  }
  if (findings.length) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
