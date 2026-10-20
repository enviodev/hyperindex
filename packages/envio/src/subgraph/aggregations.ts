/**
 * Timeseries and aggregations, as graph-node does them (docs/aggregations.md,
 * store/postgres/src/relational/rollup.rs).
 *
 * A timeseries entity is written like any entity, except that the runtime sets
 * its `id` (Int8, `block << 32 | sequence`, increasing in insertion order) and
 * its `timestamp` (the block's time). An aggregation is rolled up from those
 * rows into one entity per interval, `<Aggregation>_<hour|day>`, when a block
 * crosses the interval's boundary: the first bucket between the previous block
 * time and this one is aggregated and written, exactly as `Layout::rollup`.
 *
 * Everything here is a function of the stored rows plus two kinds of entities
 * (`EnvioSubgraphRollup`: the time of the last block seen, and the latest
 * cumulative values per group). Both are ordinary entities, so reorg rollback
 * restores them with the rest, and a restart picks up where the data left off.
 */
import BigNumber from "bignumber.js";

// ---------------------------------------------------------------------------
// Schema shapes (from the Rust translation)
// ---------------------------------------------------------------------------

export type Aggregate = {
  field: string;
  /** The aggregation table's column: `<field>_id` for an entity reference. */
  column?: string;
  func: "sum" | "count" | "min" | "max" | "first" | "last";
  arg?: string;
  cumulative: boolean;
  /** `first`/`last` also take a String, Bytes or entity reference (graph-node v0.42). */
  kind: "Int" | "Int8" | "BigInt" | "BigDecimal" | "String" | "Bytes" | "Reference";
};

const isPicked = (kind: Aggregate["kind"]) => kind === "String" || kind === "Bytes" || kind === "Reference";

/** A picked (non-numeric) value as the cumulative state keeps it: text. */
function pickedText(value: unknown): string {
  return value instanceof Uint8Array ? `0x${Buffer.from(value).toString("hex")}` : String(value);
}

export type AggregationDef = {
  name: string;
  source: string;
  intervals: ("hour" | "day")[];
  dimensions: { field: string; column: string }[];
  aggregates: Aggregate[];
};

export const INTERVAL_MICROS: Record<string, bigint> = {
  hour: 3_600_000_000n,
  day: 86_400_000_000n,
};

export const ROLLUP_STATE_ENTITY = "EnvioSubgraphRollup";

/** The entity an aggregation's interval is stored as. */
export function aggregationEntity(name: string, interval: string): string {
  return `${name}_${interval}`;
}

/** Start of the bucket (microseconds since the epoch) a time falls in. */
export function bucketIndex(micros: bigint, interval: string): bigint {
  const size = INTERVAL_MICROS[interval];
  // Block times are after the epoch; flooring division for completeness.
  const q = micros / size;
  return micros % size < 0n ? q - 1n : q;
}

/**
 * Time ranges of the buckets that overlap `from..to` and end before `to`,
 * oldest first (`AggregationInterval::buckets`). The rollup only ever needs
 * the first.
 */
export function bucketsBetween(
  from: bigint,
  to: bigint,
  interval: string,
): { start: bigint; end: bigint }[] {
  const size = INTERVAL_MICROS[interval];
  const first = bucketIndex(from, interval);
  const last = bucketIndex(to, interval);
  const buckets = [];
  for (let n = first; n < last; n = n + 1n) buckets.push({ start: n * size, end: (n + 1n) * size });
  return buckets;
}

// ---------------------------------------------------------------------------
// Numbers
// ---------------------------------------------------------------------------

const Big = BigNumber.clone({ DECIMAL_PLACES: 40, ROUNDING_MODE: BigNumber.ROUND_HALF_UP });

/** A numeric scalar with Postgres' notion of whether it is an integer type. */
type Num = { v: BigNumber; int: boolean };
type Val = Num | boolean | string | null;

function toNum(value: unknown, int = false): Num | null {
  if (value === null || value === undefined) return null;
  if (typeof value === "bigint") return { v: new Big(value.toString()), int };
  if (typeof value === "number") return { v: new Big(value), int: int || Number.isInteger(value) };
  if (typeof value === "string") {
    const parsed = new Big(value);
    return parsed.isNaN() ? null : { v: parsed, int: false };
  }
  if (BigNumber.isBigNumber(value)) return { v: new Big(value as BigNumber), int: false };
  if (value instanceof Date) return { v: new Big(value.getTime()).times(1000), int: false };
  return null;
}

// ---------------------------------------------------------------------------
// Expressions: the SQL subset graph-node lets an `arg` use
// ---------------------------------------------------------------------------

type Token =
  | { t: "num"; v: string }
  | { t: "str"; v: string }
  | { t: "id"; v: string }
  | { t: "op"; v: string }
  | { t: "end" };

const KEYWORDS = new Set([
  "and",
  "or",
  "not",
  "is",
  "null",
  "true",
  "false",
  "distinct",
  "from",
  "case",
  "when",
  "then",
  "else",
  "end",
]);

function tokenize(source: string): Token[] {
  const tokens: Token[] = [];
  let i = 0;
  while (i < source.length) {
    const c = source[i];
    if (/\s/.test(c)) {
      i++;
    } else if (/[0-9]/.test(c) || (c === "." && /[0-9]/.test(source[i + 1] ?? ""))) {
      const m = /^(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?/.exec(source.slice(i))!;
      tokens.push({ t: "num", v: m[0] });
      i += m[0].length;
    } else if (/[A-Za-z_]/.test(c)) {
      const m = /^[A-Za-z_][A-Za-z0-9_]*/.exec(source.slice(i))!;
      tokens.push({ t: "id", v: m[0] });
      i += m[0].length;
    } else if (c === '"') {
      const end = source.indexOf('"', i + 1);
      if (end < 0) throw new Error(`unterminated quoted identifier in "${source}"`);
      tokens.push({ t: "id", v: source.slice(i + 1, end) });
      i = end + 1;
    } else if (c === "'") {
      let value = "";
      i++;
      while (i < source.length && !(source[i] === "'" && source[i + 1] !== "'")) {
        value += source[i] === "'" ? "'" : source[i];
        i += source[i] === "'" ? 2 : 1;
      }
      i++;
      tokens.push({ t: "str", v: value });
    } else {
      const three = source.slice(i, i + 3);
      const two = source.slice(i, i + 2);
      if (three === "<->") {
        tokens.push({ t: "op", v: three });
        i += 3;
      } else if (["<=", ">=", "<>", "!="].includes(two)) {
        tokens.push({ t: "op", v: two === "<>" ? "!=" : two });
        i += 2;
      } else if ("+-*/%^=<>(),".includes(c)) {
        tokens.push({ t: "op", v: c });
        i++;
      } else {
        throw new Error(`unexpected "${c}" in the aggregate expression "${source}"`);
      }
    }
  }
  tokens.push({ t: "end" });
  return tokens;
}

type Row = Record<string, unknown>;
type Expr = (row: Row) => Val;

/** Compiles an `@aggregate(arg:)` expression to a function of a source row. */
export function compileExpression(
  source: string,
  column: (field: string) => string,
  fieldIsInteger: (field: string) => boolean,
): Expr {
  const tokens = tokenize(source);
  let pos = 0;
  const peek = () => tokens[pos];
  const next = () => tokens[pos++];
  const isOp = (v: string) => peek().t === "op" && (peek() as { v: string }).v === v;
  const isKw = (v: string) => peek().t === "id" && (peek() as { v: string }).v.toLowerCase() === v;
  const fail = (what: string): never => {
    throw new Error(`cannot read the aggregate expression "${source}": ${what}`);
  };
  const expectOp = (v: string) => {
    if (!isOp(v)) fail(`expected "${v}"`);
    pos++;
  };
  const expectKw = (v: string) => {
    if (!isKw(v)) fail(`expected ${v}`);
    pos++;
  };

  const num = (value: Val): Num | null => {
    if (value === null) return null;
    if (typeof value === "object") return value;
    if (typeof value === "boolean") return { v: new Big(value ? 1 : 0), int: true };
    return toNum(value);
  };
  const truthy = (value: Val): boolean | null => (value === null ? null : Boolean(typeof value === "object" ? !value.v.isZero() : value));
  const binary = (op: string, a: Val, b: Val): Val => {
    const x = num(a);
    const y = num(b);
    if (x === null || y === null) return null;
    const int = x.int && y.int;
    switch (op) {
      case "+":
        return { v: x.v.plus(y.v), int };
      case "-":
        return { v: x.v.minus(y.v), int };
      case "*":
        return { v: x.v.times(y.v), int };
      case "/":
        if (y.v.isZero()) throw new Error("division by zero in an aggregate expression");
        return int
          ? { v: x.v.div(y.v).integerValue(BigNumber.ROUND_DOWN), int }
          : { v: x.v.div(y.v), int };
      case "%":
        if (y.v.isZero()) throw new Error("division by zero in an aggregate expression");
        return { v: x.v.mod(y.v), int };
      case "^":
        return { v: x.v.pow(y.v.toNumber()), int: false };
      default:
        return fail(`operator ${op}`);
    }
  };
  const compare = (op: string, a: Val, b: Val): Val => {
    if (a === null || b === null) return null;
    const x = typeof a === "object" || typeof b === "object" ? num(a) : null;
    const y = x ? num(b) : null;
    let c: number;
    if (x && y) c = x.v.comparedTo(y.v) ?? 0;
    else c = String(a) < String(b) ? -1 : String(a) > String(b) ? 1 : 0;
    switch (op) {
      case "=":
        return c === 0;
      case "!=":
        return c !== 0;
      case "<":
        return c < 0;
      case "<=":
        return c <= 0;
      case ">":
        return c > 0;
      default:
        return c >= 0;
    }
  };

  // Precedence, lowest first: or, and, not, comparison / is, + -, * / %, ^, unary -.
  const parseOr = (): Expr => {
    let left = parseAnd();
    while (isKw("or")) {
      pos++;
      const l = left;
      const r = parseAnd();
      left = (row) => {
        const a = truthy(l(row));
        const b = truthy(r(row));
        if (a === true || b === true) return true;
        return a === null || b === null ? null : false;
      };
    }
    return left;
  };
  const parseAnd = (): Expr => {
    let left = parseNot();
    while (isKw("and")) {
      pos++;
      const l = left;
      const r = parseNot();
      left = (row) => {
        const a = truthy(l(row));
        const b = truthy(r(row));
        if (a === false || b === false) return false;
        return a === null || b === null ? null : true;
      };
    }
    return left;
  };
  const parseNot = (): Expr => {
    if (isKw("not")) {
      pos++;
      const inner = parseNot();
      return (row) => {
        const v = truthy(inner(row));
        return v === null ? null : !v;
      };
    }
    return parseComparison();
  };
  const parseComparison = (): Expr => {
    let left = parseAdditive();
    for (;;) {
      const t = peek();
      if (t.t === "op" && ["=", "!=", "<", "<=", ">", ">="].includes(t.v)) {
        pos++;
        const op = t.v;
        const l = left;
        const r = parseAdditive();
        left = (row) => compare(op, l(row), r(row));
      } else if (t.t === "op" && t.v === "<->") {
        pos++;
        const l = left;
        const r = parseAdditive();
        left = (row) => {
          const x = num(l(row));
          const y = num(r(row));
          return x && y ? { v: x.v.minus(y.v).abs(), int: x.int && y.int } : null;
        };
      } else if (isKw("is")) {
        pos++;
        let negate = false;
        if (isKw("not")) {
          pos++;
          negate = true;
        }
        const l = left;
        if (isKw("distinct")) {
          pos++;
          expectKw("from");
          const r = parseAdditive();
          left = (row) => {
            const a = l(row);
            const b = r(row);
            const same = a === null || b === null ? a === b : compare("=", a, b) === true;
            return negate ? same : !same;
          };
        } else if (isKw("null")) {
          pos++;
          left = (row) => (l(row) === null) !== negate;
        } else if (isKw("true") || isKw("false")) {
          const want = isKw("true");
          pos++;
          left = (row) => (truthy(l(row)) === want) !== negate;
        } else {
          fail("expected null, true, false or distinct from after is");
        }
      } else {
        return left;
      }
    }
  };
  const parseAdditive = (): Expr => {
    let left = parseMultiplicative();
    while (isOp("+") || isOp("-")) {
      const op = (next() as { v: string }).v;
      const l = left;
      const r = parseMultiplicative();
      left = (row) => binary(op, l(row), r(row));
    }
    return left;
  };
  const parseMultiplicative = (): Expr => {
    let left = parsePower();
    while (isOp("*") || isOp("/") || isOp("%")) {
      const op = (next() as { v: string }).v;
      const l = left;
      const r = parsePower();
      left = (row) => binary(op, l(row), r(row));
    }
    return left;
  };
  const parsePower = (): Expr => {
    const base = parseUnary();
    if (isOp("^")) {
      pos++;
      const exponent = parsePower();
      return (row) => binary("^", base(row), exponent(row));
    }
    return base;
  };
  const parseUnary = (): Expr => {
    if (isOp("-")) {
      pos++;
      const inner = parseUnary();
      return (row) => {
        const x = num(inner(row));
        return x ? { v: x.v.negated(), int: x.int } : null;
      };
    }
    if (isOp("+")) {
      pos++;
      return parseUnary();
    }
    return parsePrimary();
  };
  const args = (): Expr[] => {
    expectOp("(");
    const list: Expr[] = [];
    if (!isOp(")")) {
      list.push(parseOr());
      while (isOp(",")) {
        pos++;
        list.push(parseOr());
      }
    }
    expectOp(")");
    return list;
  };
  const parsePrimary = (): Expr => {
    const t = next();
    if (t.t === "num") {
      const literal: Num = { v: new Big(t.v), int: /^\d+$/.test(t.v) };
      return () => literal;
    }
    if (t.t === "str") return () => t.v;
    if (t.t === "op" && t.v === "(") {
      const inner = parseOr();
      expectOp(")");
      return inner;
    }
    if (t.t !== "id") return fail("unexpected end");
    const word = t.v.toLowerCase();
    if (word === "null") return () => null;
    if (word === "true") return () => true;
    if (word === "false") return () => false;
    if (word === "case") {
      const subject = isKw("when") ? null : parseOr();
      const arms: [Expr, Expr][] = [];
      while (isKw("when")) {
        pos++;
        const cond = parseOr();
        expectKw("then");
        arms.push([cond, parseOr()]);
      }
      let otherwise: Expr = () => null;
      if (isKw("else")) {
        pos++;
        otherwise = parseOr();
      }
      expectKw("end");
      return (row) => {
        const s = subject ? subject(row) : true;
        for (const [cond, result] of arms) {
          const c = cond(row);
          if (subject ? compare("=", s, c) === true : truthy(c) === true) return result(row);
        }
        return otherwise(row);
      };
    }
    if (isOp("(") && !KEYWORDS.has(word)) {
      const list = args();
      const arg = (row: Row, n: number) => num(list[n](row));
      const unary = (f: (x: BigNumber) => BigNumber, keepInt = false): Expr => (row) => {
        const x = arg(row, 0);
        return x ? { v: f(x.v), int: keepInt && x.int } : null;
      };
      switch (word) {
        case "abs":
          return unary((x) => x.abs(), true);
        case "ceil":
        case "ceiling":
          return unary((x) => x.integerValue(BigNumber.ROUND_CEIL), false);
        case "floor":
          return unary((x) => x.integerValue(BigNumber.ROUND_FLOOR), false);
        case "sign":
          return unary((x) => new Big(x.isZero() ? 0 : x.isNegative() ? -1 : 1), true);
        case "div":
          return (row) => {
            const x = arg(row, 0);
            const y = arg(row, 1);
            return x && y ? { v: x.v.div(y.v).integerValue(BigNumber.ROUND_DOWN), int: false } : null;
          };
        case "mod":
          return (row) => binary("%", list[0](row), list[1](row));
        case "power":
          return (row) => binary("^", list[0](row), list[1](row));
        case "gcd":
        case "lcm":
          return (row) => {
            const x = arg(row, 0);
            const y = arg(row, 1);
            if (!x || !y) return null;
            let a = x.v.abs();
            let b = y.v.abs();
            while (!b.isZero()) [a, b] = [b, a.mod(b)];
            return word === "gcd"
              ? { v: a, int: true }
              : { v: a.isZero() ? a : x.v.times(y.v).abs().div(a), int: true };
          };
        case "coalesce":
          return (row) => {
            for (const item of list) {
              const v = item(row);
              if (v !== null) return v;
            }
            return null;
          };
        case "nullif":
          return (row) => {
            const a = list[0](row);
            return compare("=", a, list[1](row)) === true ? null : a;
          };
        case "greatest":
        case "least":
          return (row) => {
            let best: Num | null = null;
            for (const item of list) {
              const v = num(item(row));
              if (v === null) continue;
              if (best === null || (word === "greatest" ? v.v.gt(best.v) : v.v.lt(best.v))) best = v;
            }
            return best;
          };
        default:
          return fail(`the function ${t.v}`);
      }
    }
    // A source field.
    const field = t.v;
    const col = column(field);
    const isInt = fieldIsInteger(field);
    return (row) => {
      const raw = row[col];
      if (typeof raw === "boolean") return raw;
      if (typeof raw === "string" && !/^-?\d/.test(raw)) return raw;
      return toNum(raw, isInt);
    };
  };

  const expr = parseOr();
  if (peek().t !== "end") fail(`unexpected input after the expression`);
  return expr;
}

// ---------------------------------------------------------------------------
// Rolling a bucket up
// ---------------------------------------------------------------------------

export type SourceFields = {
  /** The declared scalar of each source field (`Int`, `BigDecimal`, ...). */
  kinds: Record<string, string>;
  /** Relation fields, whose column is `<field>_id`. */
  refs: Set<string>;
};

export function columnOf(fields: SourceFields, field: string): string {
  return fields.refs.has(field) ? `${field}_id` : field;
}

/** Compiled `arg`s of one aggregation, reusable across buckets. */
export type CompiledAggregation = {
  def: AggregationDef;
  args: (Expr | null)[];
};

export function compileAggregation(def: AggregationDef, fields: SourceFields): CompiledAggregation {
  const args = def.aggregates.map((aggregate): Expr | null => {
    if (aggregate.arg === undefined) return null;
    // A String, Bytes or reference `first`/`last` names a source field of its
    // type (graph-node's `check_ident`): its value is taken as stored.
    if (isPicked(aggregate.kind)) {
      const column = columnOf(fields, aggregate.arg.trim().replace(/^"(.*)"$/, "$1"));
      return (row) => (row[column] ?? null) as Val;
    }
    return compileExpression(
      aggregate.arg,
      (field) => columnOf(fields, field),
      (field) => fields.kinds[field] === "Int" || fields.kinds[field] === "Int8",
    );
  });
  return { def, args };
}

/** The cumulative state kept for a group: the last row's values for each cumulative aggregate. */
export type PrevState = Record<string, string | null>;

export type BucketRow = {
  id: bigint;
  dimensions: Record<string, unknown>;
  values: Record<string, unknown>;
  /** The cumulative values to store as the group's new `prev`. */
  next: PrevState;
  dimKey: string;
};

function dimKeyOf(value: unknown): unknown {
  if (value instanceof Uint8Array) return `0x${Buffer.from(value).toString("hex")}`;
  if (typeof value === "bigint") return value.toString();
  if (value instanceof Date) return value.getTime();
  return value ?? null;
}

function idOf(row: Row): bigint {
  return BigInt(String(row.id));
}

/**
 * Aggregates the rows of one bucket (`select_bucket`), grouped by the
 * dimensions, and folds in each group's previous cumulative values
 * (`select_combined`). `prev` answers the lookup of a group's last stored
 * cumulative state by its key.
 */
export function rollupBucket(
  compiled: CompiledAggregation,
  rows: Row[],
  prev: (dimKey: string) => PrevState | null,
): BucketRow[] {
  const { def, args } = compiled;
  const groups = new Map<string, Row[]>();
  for (const row of rows) {
    const key = JSON.stringify(def.dimensions.map((d) => dimKeyOf(row[d.column])));
    const group = groups.get(key);
    if (group) group.push(row);
    else groups.set(key, [row]);
  }

  const out: BucketRow[] = [];
  for (const [dimKey, group] of groups) {
    // first/last order by id, which graph-node sets in insertion order.
    group.sort((a, b) => {
      const x = idOf(a);
      const y = idOf(b);
      return x < y ? -1 : x > y ? 1 : 0;
    });
    const previous = def.aggregates.some((a) => a.cumulative) ? prev(dimKey) : null;
    const values: Record<string, unknown> = {};
    const next: PrevState = {};
    def.aggregates.forEach((aggregate, index) => {
      const arg = args[index];
      const evaluated: Val[] = aggregate.func === "count" ? [] : group.map((row) => arg!(row));
      if (isPicked(aggregate.kind)) {
        // arg_min/arg_max by id over the non-null values; a cumulative one
        // keeps the earlier bucket's for `first`, takes this one's for `last`.
        const present = evaluated.filter((v) => v !== null && v !== undefined) as unknown[];
        const bucket = present.length === 0 ? null : aggregate.func === "first" ? present[0] : present[present.length - 1];
        let value: unknown = bucket;
        if (aggregate.cumulative) {
          const before = previous?.[aggregate.field];
          const p = before === undefined || before === null ? null : before;
          if (p !== null && (aggregate.func === "first" || bucket === null)) {
            value = aggregate.kind === "Bytes" ? new Uint8Array(Buffer.from(p.slice(2), "hex")) : p;
          }
          next[aggregate.field] = value === null ? null : pickedText(value);
        }
        values[aggregate.field] = value;
        return;
      }
      const nums = evaluated.map((v) => (v === null ? null : num_(v))).filter((n): n is Num => n !== null);
      let bucket: Num | null;
      switch (aggregate.func) {
        case "count":
          bucket = { v: new Big(group.length), int: true };
          break;
        case "sum":
          bucket = nums.length === 0 ? null : { v: BigNumber.sum.apply(null, nums.map((n) => n.v) as any), int: nums.every((n) => n.int) };
          break;
        case "min":
          bucket = nums.length === 0 ? null : nums.reduce((a, b) => (b.v.lt(a.v) ? b : a));
          break;
        case "max":
          bucket = nums.length === 0 ? null : nums.reduce((a, b) => (b.v.gt(a.v) ? b : a));
          break;
        case "first":
          bucket = nums[0] ?? null;
          break;
        default:
          bucket = nums.length === 0 ? null : nums[nums.length - 1];
      }
      let value = bucket;
      if (aggregate.cumulative) {
        const before = previous?.[aggregate.field];
        const p: Num | null = before === undefined || before === null ? null : { v: new Big(before), int: false };
        if (p !== null) {
          switch (aggregate.func) {
            case "count":
            case "sum":
              value = bucket === null ? p : { v: p.v.plus(bucket.v), int: p.int && bucket.int };
              break;
            case "min":
              value = bucket === null || p.v.lte(bucket.v) ? p : bucket;
              break;
            case "max":
              value = bucket === null || p.v.gte(bucket.v) ? p : bucket;
              break;
            case "first":
              value = p;
              break;
            default:
              value = bucket ?? p;
          }
        }
        next[aggregate.field] = value === null ? null : value.v.toFixed();
      }
      values[aggregate.field] = value;
    });
    const dimensions: Record<string, unknown> = {};
    for (const d of def.dimensions) dimensions[d.column] = group[0][d.column] ?? null;
    out.push({
      id: group.reduce((max, row) => (idOf(row) > max ? idOf(row) : max), idOf(group[0])),
      dimensions,
      values,
      next,
      dimKey,
    });
  }
  return out;
}

function num_(v: Val): Num | null {
  if (v === null) return null;
  if (typeof v === "object") return v;
  if (typeof v === "boolean") return { v: new Big(v ? 1 : 0), int: true };
  return toNum(v);
}

/** A rolled-up value as the column holds it. */
export function storedValue(value: unknown, kind: Aggregate["kind"]): unknown {
  if (value === null || value === undefined) return null;
  if (isPicked(kind)) return value;
  const num = value as Num;
  switch (kind) {
    case "Int": {
      const n = num.v.integerValue(BigNumber.ROUND_HALF_UP).toNumber();
      return n;
    }
    case "Int8":
    case "BigInt":
      return BigInt(num.v.integerValue(BigNumber.ROUND_HALF_UP).toFixed(0));
    default:
      return new BigNumber(num.v);
  }
}
