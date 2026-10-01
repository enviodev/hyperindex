/**
 * The runtime half of `packages/cli/src/subgraph/assemblyscript.rs`, which
 * rewrites every arithmetic and comparison operator in a mapping into a call
 * on `OPERATORS_HELPER`, every `changetype<Foo>(x)` into one to `RETAG_HELPER`,
 * and exports each handler's event class as `EVENT_CLASSES_EXPORT`. The names
 * are shared with that file.
 */

export const OPERATORS_HELPER = "__envio_op";
export const RETAG_HELPER = "__envio_retag";
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
    // Only i64 / i64 stays 64-bit; anything narrower is an i32 in AssemblyScript
    // and must come back as a number, or the bigint spreads through every
    // arithmetic that follows.
    if (typeof left === "bigint" && typeof right === "bigint") {
      return left / right;
    }
    return Math.trunc(Number(left) / Number(right));
  }
  return (left as number) / (right as number);
}

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
 * graph-ts overloads the arithmetic and comparison operators on `BigInt`,
 * `BigDecimal` and `ByteArray`, and AssemblyScript calls the overload: a
 * JavaScript operator would coerce them, or compare their identity — so
 * `address == ZERO_ADDRESS` would always be false.
 */
export const operators = {
  add: binary("plus", (a, b) => a + b),
  sub: binary("minus", (a, b) => a - b),
  mul: binary("times", (a, b) => a * b),
  div: binary("div", integerDivision),
  rem: binary("mod", (a, b) => a % b),
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
};
