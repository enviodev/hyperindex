/**
 * The runtime half of `packages/cli/src/subgraph/assemblyscript.rs`, which
 * rewrites every arithmetic and comparison operator in a mapping into a call
 * on `OPERATORS_HELPER`, every `changetype<Foo>(x)` into one to `RETAG_HELPER`,
 * and exports each handler's event class as `EVENT_CLASSES_EXPORT`. The names
 * are shared with that file.
 */

import { BigDecimal, BigInt as GraphBigInt } from "./graph-ts.ts";

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
 * AssemblyScript's `===`, which no class can overload: references are the same
 * object, numbers the same value once converted to a common type — an i64 the
 * shim holds as a bigint equals the number it was compared with, and a bool is
 * 0 or 1. Null is one value however the JavaScript side came to read it: a
 * class field AssemblyScript zero-initializes is `undefined` here.
 */
const same = (a: unknown, b: unknown): boolean => {
  if (a === b) return true;
  if (a == null || b == null) return a == null && b == null;
  const numeric = (v: unknown) => typeof v === "number" || typeof v === "bigint" || typeof v === "boolean";
  if (numeric(a) && numeric(b) && typeof a !== typeof b) {
    const n = (v: unknown) => (typeof v === "boolean" ? (v ? 1 : 0) : v);
    return n(a) == n(b);
  }
  return false;
};

/**
 * `===` where one side is a string the host has just allocated (the transform
 * marks it): no other string is that allocation, whatever it reads.
 */
const sameFresh = (a: unknown, b: unknown): boolean =>
  typeof a === "string" && typeof b === "string" ? false : same(a, b);

/**
 * `x as i32` and its narrower kin. A number or bigint wraps to the width; a
 * boolean is 0 or 1; null is 0. Anything else is a reference, and an
 * AssemblyScript cast of one reads its address, which is garbage the mapping
 * never meant — revert-univ3 casts a call result — so it comes out as 0
 * rather than the NaN that `BigInt.fromI32` then refuses.
 */
const wrapTo = (bits: number, signed: boolean) => (value: unknown): number => {
  let n: number;
  if (typeof value === "bigint") n = Number(BigInt.asIntN(32, value));
  else if (typeof value === "number") n = value;
  else if (typeof value === "boolean") n = value ? 1 : 0;
  else n = 0;
  if (!Number.isFinite(n)) return 0;
  const wrapped = (Math.trunc(n) | 0) as number;
  if (bits === 32) return signed ? wrapped : wrapped >>> 0;
  const mask = (1 << bits) - 1;
  const low = wrapped & mask;
  return signed && low >= 1 << (bits - 1) ? low - (1 << bits) : low;
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
 * What a graph-ts method on a null receiver computes below apiVersion 0.0.5,
 * where the host reads the null pointer as an empty value: a zero. Which zero
 * follows the argument (`null.plus(decimal)` is a decimal's), and a bytes
 * receiver is empty.
 */
const nullReceiver: Record<string, (...args: any[]) => unknown> = {};
const zeroFor = (other: unknown): any =>
  other instanceof BigDecimal ? BigDecimal.zero() : GraphBigInt.zero();
for (const method of [
  "plus",
  "minus",
  "times",
  "div",
  "mod",
  "pow",
  "bitOr",
  "bitAnd",
  "leftShift",
  "rightShift",
  "abs",
  "neg",
  "toString",
  "toI32",
  "toBigDecimal",
  "isZero",
  "lt",
  "le",
  "gt",
  "ge",
]) {
  nullReceiver[method] = (...args) => zeroFor(args[0])[method](...args);
}
nullReceiver.truncate = (...args) => BigDecimal.zero().truncate(args[0]);
nullReceiver.toHex = nullReceiver.toHexString = () => "0x";
nullReceiver.equals = (other) =>
  other === null || other === undefined
    ? true
    : other instanceof Uint8Array && !(other instanceof GraphBigInt)
      ? other.length === 0
      : zeroFor(other).equals(other);
nullReceiver.notEqual = (other) => !nullReceiver.equals(other);

/**
 * graph-ts overloads the arithmetic and comparison operators on `BigInt`,
 * `BigDecimal` and `ByteArray`, and AssemblyScript calls the overload: a
 * JavaScript operator would coerce them, or compare their identity — so
 * `address == ZERO_ADDRESS` would always be false.
 */
export const operators = {
  recv: (receiver: any): any => receiver ?? nullReceiver,
  add: binary("plus", widened((a, b) => a + b)),
  sub: binary("minus", widened((a, b) => a - b)),
  mul: binary("times", widened((a, b) => a * b)),
  div: binary("div", integerDivision),
  rem: binary("mod", widened((a, b) => a % b)),
  // `10 ** decimals.toI64()` is an i64 power, and graph-ts' `BigInt ** u8` its
  // `pow`: JavaScript's `**` refuses to mix a bigint with a number.
  pow: (a: unknown, b: unknown): unknown => {
    const declared = isObject(a) ? overload(a, "pow") : undefined;
    if (declared) return declared.call(a, typeof b === "bigint" ? Number(b) : b);
    if (typeof a === "bigint" || typeof b === "bigint") return BigInt(a as bigint | number) ** BigInt(b as bigint | number);
    return (a as number) ** (b as number);
  },
  eq: equals,
  ne: (a: unknown, b: unknown) => !equals(a, b),
  same,
  same_fresh: sameFresh,
  lt: binary("lt", (a, b) => a < b),
  le: binary("le", (a, b) => a <= b),
  gt: binary("gt", (a, b) => a > b),
  ge: binary("ge", (a, b) => a >= b),
  as_i8: wrapTo(8, true),
  as_u8: wrapTo(8, false),
  as_i16: wrapTo(16, true),
  as_u16: wrapTo(16, false),
  as_i32: wrapTo(32, true),
  as_u32: wrapTo(32, false),
  neg: (a: unknown) => {
    const declared = overload(a, "neg");
    return declared ? declared.call(a) : -(a as number);
  },
  indexOf: search("indexOf"),
  lastIndexOf: search("lastIndexOf"),
  includes: search("includes"),
};
