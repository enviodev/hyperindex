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
 * Usage (needs Hasura 8080 + envio serve 8081, fixture applied):
 *   pnpm fuzz:differential -- [--seeds 1..20] [--n 500] [--concurrency 8]
 *                             [--admin-ratio 0.3] [--verbose]
 */

import { hasuraUrl, serveUrl, adminSecret } from "./env.js";
import { arg, flag } from "./cliArgs.js";

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
}

function render(node: Node, indent = ""): string {
  const args = node.args.length
    ? `(${node.args.map(([k, v]) => `${k}: ${v}`).join(", ")})`
    : "";
  const name = node.alias ? `${node.alias}: ${node.field}` : node.field;
  if (!node.children.length) return `${indent}${name}${args}`;
  const inner = node.children.map((c) => render(c, indent + "  ")).join("\n");
  return `${indent}${name}${args} {\n${inner}\n${indent}}`;
}

function renderQuery(roots: Node[]): string {
  return `{\n${roots.map((r) => render(r, "  ")).join("\n")}\n}`;
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
    const chosen = rng.sample(fields, 1, Math.min(2, fields.length));
    const body = chosen
      .map(
        (f) =>
          `${f.name}: ${inputLiteral(rng, schema, f.type, wellTyped, depth + 1)}`
      )
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
}

function genSelection(
  rng: Rng,
  schema: Schema,
  typeName: string,
  depth: number,
  opts: GenOptions
): Node[] {
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
        out.push({
          field: f.name,
          args: genArgs(rng, schema, f, inner, opts),
          children,
        });
    }
  }
  if (rng.chance(0.12))
    out.push({ field: "__typename", args: [], children: [] });
  if (rng.chance(0.1) && out.length)
    out[0] = { ...out[0]!, alias: `a${rng.int(0, 99)}` };
  return out;
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
  const wellTyped = () => rng.chance(opts.wellTypedRatio);

  if (byName.has("limit") && rng.chance(0.6))
    args.push(["limit", String(rng.int(0, 5))]);
  if (byName.has("offset") && rng.chance(0.25))
    args.push(["offset", String(rng.int(0, 3))]);
  if (byName.has("order_by") && rng.chance(0.5)) {
    const cols = schema.scalarFields(returnedType);
    if (cols.length) {
      const picked = rng.sample(cols, 1, 2);
      const body = picked
        .map((c) => `${c.name}: ${rng.pick(ORDER_BY)}`)
        .join(", ");
      args.push(["order_by", rng.chance(0.3) ? `[{${body}}]` : `{${body}}`]);
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
    args.push([a.name, inputLiteral(rng, schema, a.type, wellTyped())]);
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
  const wellTyped = rng.chance(opts.wellTypedRatio);
  return `{${col.name}: {${op.name}: ${inputLiteral(rng, schema, op.type, wellTyped)}}}`;
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
    roots.push({
      field: root.name,
      alias: count > 1 ? `r${i}` : undefined,
      args: genArgs(rng, schema, root, returned.name, opts),
      children: children.length
        ? children
        : [{ field: "__typename", args: [], children: [] }],
    });
  }
  return roots;
}

// ---------------------------------------------------------------------------
// Execution and comparison

interface Response {
  status: number;
  body: string;
}

async function post(url: string, query: string, admin: boolean): Promise<Response> {
  const res = await fetch(`${url}${url.endsWith("/v1/graphql") ? "" : "/v1/graphql"}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(admin ? { "x-hasura-admin-secret": adminSecret } : {}),
    },
    body: JSON.stringify({ query }),
  });
  return { status: res.status, body: await res.text() };
}

function canonical(body: string): string {
  try {
    return JSON.stringify(sortDeep(JSON.parse(body)));
  } catch {
    return body;
  }
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
  query: string,
  admin: boolean
): Promise<{ hasura: Response; serve: Response } | null> {
  const [hasura, serve] = await Promise.all([
    post(hasuraUrl, query, admin),
    post(serveUrl, query, admin),
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
    // Drop an alias.
    if (node.alias) out.push(rebuild({ ...node, alias: undefined }));
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

async function shrink(roots: Node[], admin: boolean): Promise<Node[]> {
  let current = roots;
  let improved = true;
  let budget = 300;
  while (improved && budget > 0) {
    improved = false;
    for (const candidate of reductions(current)) {
      if (budget-- <= 0) break;
      if (await differs(renderQuery(candidate), admin)) {
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

// ---------------------------------------------------------------------------

interface Finding {
  seed: number;
  index: number;
  query: string;
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

  const schema = await Schema.load(serveUrl);
  console.log(
    `fuzzing ${schema.roots.length} root fields, seeds ${seedLo}..${seedHi} x ${perSeed}`
  );

  const opts: GenOptions = { wellTypedRatio, maxDepth: 2 };
  const bySignature = new Map<string, Finding>();
  let checked = 0;
  let hits = 0;

  for (let seed = seedLo!; seed <= seedHi!; seed++) {
    const rng = new Rng(seed);
    // Generate the whole seed's batch up front so query N depends only on the
    // seed, never on how requests interleaved.
    const batch = Array.from({ length: perSeed }, (_, index) => ({
      index,
      roots: generate(rng, schema, opts),
      admin: rng.chance(adminRatio),
    }));

    let cursor = 0;
    await Promise.all(
      Array.from({ length: concurrency }, async () => {
        while (cursor < batch.length) {
          const item = batch[cursor++]!;
          const query = renderQuery(item.roots);
          let diff;
          try {
            diff = await differs(query, item.admin);
          } catch (err) {
            console.error(`request failed: ${err}`);
            continue;
          }
          checked++;
          if (!diff) continue;
          hits++;
          const sig = signature(diff.hasura, diff.serve);
          if (bySignature.has(sig)) continue;
          // Placeholder first so concurrent workers don't shrink duplicates.
          bySignature.set(sig, {
            seed,
            index: item.index,
            query,
            admin: item.admin,
            hasura: diff.hasura.body,
            serve: diff.serve.body,
          });
          const small = await shrink(item.roots, item.admin);
          const smallQuery = renderQuery(small);
          const reDiff = await differs(smallQuery, item.admin);
          if (reDiff)
            bySignature.set(sig, {
              seed,
              index: item.index,
              query: smallQuery,
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
    `\nchecked ${checked}, mismatching responses ${hits}, distinct shapes ${findings.length}`
  );
  for (const f of findings) {
    console.log(
      `\n--- seed ${f.seed} #${f.index}${f.admin ? " (admin)" : ""}\n${f.query}`
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
