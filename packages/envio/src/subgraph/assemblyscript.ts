/**
 * The runtime half of `packages/cli/src/subgraph/assemblyscript.rs`, which
 * rewrites every arithmetic and comparison operator in a mapping into a call
 * on `OPERATORS_HELPER`, every `changetype<Foo>(x)` into one to `RETAG_HELPER`,
 * and exports each handler's event class as `EVENT_CLASSES_EXPORT`. The names
 * are shared with that file.
 */

export const OPERATORS_HELPER = "__envio_op";
export const RETAG_HELPER = "__envio_retag";
export const RETAG_EACH_HELPER = "__envio_retag_each";
export const EVENT_CLASSES_EXPORT = "__envio_event_classes";

/**
 * AssemblyScript divides two integers as integers; this truncates only when
 * both operands really are integers and otherwise divides as before — an `f64`
 * divides as a float in AssemblyScript too.
 */
export function integerDivision(a: unknown, b: unknown): unknown {
  const left = typeof a === "object" && a !== null ? (a as any).valueOf() : a;
  const right = typeof b === "object" && b !== null ? (b as any).valueOf() : b;

  const integral = (v: unknown) =>
    typeof v === "bigint" || (typeof v === "number" && Number.isInteger(v));
  if (integral(left) && integral(right)) {
    // An i64 on either side makes it an i64 division (the other side is a
    // literal or a widened integer); anything narrower is an i32 in
    // AssemblyScript and must come back as a number, or the bigint spreads
    // through every arithmetic that follows.
    if (typeof left === "bigint" || typeof right === "bigint") {
      return BigInt(left as bigint | number) / BigInt(right as bigint | number);
    }
    return Math.trunc(Number(left) / Number(right));
  }
  return (left as number) / (right as number);
}

/**
 * An i64 with an integer on the other side is i64 arithmetic in
 * AssemblyScript — `timestamp.toI64() * 1000` — where JavaScript refuses to
 * mix a bigint with a number.
 */
const widened =
  (op: (a: any, b: any) => unknown) =>
  (a: unknown, b: unknown): unknown => {
    if (typeof a === "bigint" && typeof b === "number" && Number.isInteger(b)) return op(a, BigInt(b));
    if (typeof b === "bigint" && typeof a === "number" && Number.isInteger(a)) return op(BigInt(a), b);
    return op(a, b);
  };

/** The graph-ts operator overload `value` declares under `method`, if any. */
function overload(value: unknown, method: string): Function | undefined {
  if (!isObject(value)) return undefined;
  const fn = (value as Record<string, unknown>)[method];
  return typeof fn === "function" ? fn : undefined;
}

function isObject(value: unknown): boolean {
  return value !== null && typeof value === "object";
}

// Both operands are objects wherever AssemblyScript picks the overload — it
// doesn't compile `BigInt < i32` — so a primitive on either side is left to
// JavaScript, which reads the object through `valueOf`.
const binary =
  (method: string, fallback: (a: any, b: any) => unknown) =>
  (a: unknown, b: unknown): unknown => {
    const declared = isObject(b) ? overload(a, method) : undefined;
    return declared ? declared.call(a, b) : fallback(a, b);
  };

// Against null AssemblyScript compares the reference, overload or not.
const equals = (a: unknown, b: unknown): boolean => {
  const declared = isObject(b) ? overload(a, "equals") : undefined;
  return declared ? (declared.call(a, b) as boolean) : a == b;
};

/**
 * AssemblyScript's `Array#indexOf`, `lastIndexOf` and `includes` compare each
 * element with `==`, so with graph-ts' overload: ENS's
 * `if (!coinTypes.includes(coinType))` finds a BigInt already there. A
 * string, a typed array, or a search for a primitive is JavaScript's own.
 */
const search =
  (method: "indexOf" | "lastIndexOf" | "includes") =>
  (receiver: any, value: unknown, from?: number): unknown => {
    if (!Array.isArray(receiver) || !overload(value, "equals")) {
      return from === undefined ? receiver[method](value) : receiver[method](value, from);
    }
    const length = receiver.length;
    if (method === "lastIndexOf") {
      let index = from === undefined ? length - 1 : from < 0 ? length + from : Math.min(from, length - 1);
      for (; index >= 0; index--) if (equals(receiver[index], value)) return index;
      return -1;
    }
    let index = from === undefined ? 0 : from < 0 ? Math.max(length + from, 0) : from;
    for (; index < length; index++) if (equals(receiver[index], value)) return method === "includes" ? true : index;
    return method === "includes" ? false : -1;
  };

/**
 * graph-ts overloads the arithmetic and comparison operators on `BigInt`,
 * `BigDecimal` and `ByteArray`, and AssemblyScript calls the overload: a
 * JavaScript operator would coerce them, or compare their identity — so
 * `address == ZERO_ADDRESS` would always be false.
 */
export const operators = {
  add: binary("plus", widened((a, b) => a + b)),
  sub: binary("minus", widened((a, b) => a - b)),
  mul: binary("times", widened((a, b) => a * b)),
  div: binary("div", integerDivision),
  rem: binary("mod", widened((a, b) => a % b)),
  eq: equals,
  ne: (a: unknown, b: unknown) => !equals(a, b),
  lt: binary("lt", (a, b) => a < b),
  le: binary("le", (a, b) => a <= b),
  gt: binary("gt", (a, b) => a > b),
  ge: binary("ge", (a, b) => a >= b),
  neg: (a: unknown) => {
    const declared = overload(a, "neg");
    return declared ? declared.call(a) : -(a as number);
  },
  indexOf: search("indexOf"),
  lastIndexOf: search("lastIndexOf"),
  includes: search("includes"),
};
