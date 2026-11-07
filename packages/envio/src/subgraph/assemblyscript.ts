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
/** Reruns a project module's top-level code for a new trigger. */
export const MODULE_INIT = "__envio_init";
export const AS_MAP = "__envio_Map";
export const AS_SET = "__envio_Set";

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

/**
 * `let result: JsonResult; result.error = "none"; return result;`: asc gives
 * the local the null pointer, and the field writes land at that address, so
 * every such local reads back what any of them wrote (one per class here, as
 * the code that relies on it writes the fields it reads). It is still null to
 * a comparison. graph-node's module memory is fresh in every trigger, and so
 * are these.
 */
let nullObjects = new Map<Function, object>();
let liveNullObjects = new WeakSet<object>();
export function resetNullObjects(): void {
  if (nullObjects.size === 0) return;
  nullObjects = new Map();
  liveNullObjects = new WeakSet();
}
const nullObject = (Class: Function): object => {
  let object = nullObjects.get(Class);
  if (!object) {
    object = Object.create(Class.prototype) as object;
    nullObjects.set(Class, object);
    liveNullObjects.add(object);
  }
  return object;
};
const asNull = (value: unknown): unknown =>
  nullObjects.size > 0 && isObject(value) && liveNullObjects.has(value as object) ? null : value;

// Against null AssemblyScript compares the reference, overload or not.
const equals = (a: unknown, b: unknown): boolean => {
  a = asNull(a);
  b = asNull(b);
  const declared = isObject(b) ? overload(a, "equals") : undefined;
  return declared ? (declared.call(a, b) as boolean) : a == b;
};

/**
 * A bit operation where either side is an i64 — a bigint here — is a 64-bit
 * one in AssemblyScript, the i32 side widened; JavaScript refuses to mix the
 * two. Two numbers keep JavaScript's int32 operation, which is an i32's.
 */
const bits64 =
  (op: (a: bigint, b: bigint) => bigint, numbers: (a: number, b: number) => number) =>
  (a: unknown, b: unknown): unknown => {
    if (typeof a !== "bigint" && typeof b !== "bigint") return numbers(a as number, b as number);
    return op(BigInt(a as bigint | number), BigInt(b as bigint | number));
  };
// A u64 stays unsigned through a left shift, an i64 keeps its sign.
const wrap64 = (from: bigint, value: bigint) => (from < 0n ? BigInt.asIntN(64, value) : BigInt.asUintN(64, value));

/**
 * AssemblyScript's `===`, which no class can overload: references are the same
 * object, numbers the same value once converted to a common type — an i64 the
 * shim holds as a bigint equals the number it was compared with, and a bool is
 * 0 or 1. Null is one value however the JavaScript side came to read it: a
 * class field AssemblyScript zero-initializes is `undefined` here.
 */
const same = (a: unknown, b: unknown): boolean => {
  a = asNull(a);
  b = asNull(b);
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
 * `changetype<usize>(ref)`: the reference's address. Null is 0 and each object
 * keeps one nonzero address, which is all a mapping can observe of one — it
 * tests it against 0, or two of them against each other. A string here is a
 * value, so equal strings share an address; an integer is itself.
 */
const objectAddresses = new WeakMap<object, number>();
const stringAddresses = new Map<string, number>();
let lastAddress = 0;
const nextAddress = () => (lastAddress += 16);
/**
 * An AssemblyScript pointer into a buffer — `x.dataStart`,
 * `changetype<usize>(x.buffer)` — for `load`, `store` and `memory.copy`, and
 * pointer arithmetic on it. As a number it is a stable address of its own.
 */
export class Pointer {
  constructor(
    readonly buffer: ArrayBufferLike,
    readonly offset: number,
  ) {}
  at(delta: number): Pointer {
    return new Pointer(this.buffer, this.offset + delta);
  }
  valueOf(): number {
    return objectAddress(this.buffer as object) + this.offset;
  }
}

const isBuffer = (value: unknown): value is ArrayBufferLike =>
  value instanceof ArrayBuffer || (typeof SharedArrayBuffer !== "undefined" && value instanceof SharedArrayBuffer);

function pointer(value: unknown, what: string): Pointer {
  if (value instanceof Pointer) return value;
  throw new Error(
    `Envio Subgraph can't ${what} at a raw memory address (${String(value)}): only a pointer into a buffer, ` +
      "from x.dataStart or changetype<usize>(x.buffer), addresses memory here.",
  );
}

type Width = { size: number; get: (view: DataView, at: number) => unknown; set: (view: DataView, at: number, value: unknown) => void };
const number = (value: unknown) => Number(typeof value === "boolean" ? Number(value) : value);
const big = (value: unknown) => (typeof value === "bigint" ? value : BigInt(Math.trunc(number(value))));
const WIDTHS: Record<string, Width> = {
  i8: { size: 1, get: (v, at) => v.getInt8(at), set: (v, at, x) => v.setInt8(at, number(x)) },
  u8: { size: 1, get: (v, at) => v.getUint8(at), set: (v, at, x) => v.setUint8(at, number(x)) },
  bool: { size: 1, get: (v, at) => v.getUint8(at) !== 0, set: (v, at, x) => v.setUint8(at, number(x) ? 1 : 0) },
  i16: { size: 2, get: (v, at) => v.getInt16(at, true), set: (v, at, x) => v.setInt16(at, number(x), true) },
  u16: { size: 2, get: (v, at) => v.getUint16(at, true), set: (v, at, x) => v.setUint16(at, number(x), true) },
  i32: { size: 4, get: (v, at) => v.getInt32(at, true), set: (v, at, x) => v.setInt32(at, number(x), true) },
  u32: { size: 4, get: (v, at) => v.getUint32(at, true), set: (v, at, x) => v.setUint32(at, number(x), true) },
  i64: { size: 8, get: (v, at) => v.getBigInt64(at, true), set: (v, at, x) => v.setBigInt64(at, BigInt.asIntN(64, big(x)), true) },
  u64: { size: 8, get: (v, at) => v.getBigUint64(at, true), set: (v, at, x) => v.setBigUint64(at, BigInt.asUintN(64, big(x)), true) },
  f32: { size: 4, get: (v, at) => v.getFloat32(at, true), set: (v, at, x) => v.setFloat32(at, number(x), true) },
  f64: { size: 8, get: (v, at) => v.getFloat64(at, true), set: (v, at, x) => v.setFloat64(at, number(x), true) },
};
WIDTHS.isize = WIDTHS.i32;
WIDTHS.usize = WIDTHS.u32;

function width(type: string): Width {
  const found = WIDTHS[type];
  if (!found) throw new Error(`Envio Subgraph can't load or store a ${type} in memory: only integer, float and bool values.`);
  return found;
}

/** AssemblyScript's `memory` builtin, over the buffers pointers address. */
export const memory = {
  copy(destination: unknown, source: unknown, length: unknown): void {
    const to = pointer(destination, "copy memory");
    const from = pointer(source, "copy memory");
    const count = number(length);
    // TypedArray#set copies an overlapping range as memmove does.
    new Uint8Array(to.buffer, to.offset, count).set(new Uint8Array(from.buffer, from.offset, count));
  },
  fill(destination: unknown, value: unknown, length: unknown): void {
    const to = pointer(destination, "fill memory");
    new Uint8Array(to.buffer, to.offset, number(length)).fill(number(value));
  },
};

const bytesAt = (buffer: unknown, what: string): Uint8Array => {
  if (isBuffer(buffer)) return new Uint8Array(buffer);
  if (ArrayBuffer.isView(buffer)) return new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength);
  throw new Error(`Envio Subgraph: String.${what} takes an ArrayBuffer, not ${String(buffer)}.`);
};

/**
 * AssemblyScript's UTF-8 decoder (std/assembly/string.ts, asc 0.19.10): it
 * validates nothing and replaces nothing, takes a lead byte's payload bits as
 * they are, and stops at a sequence the input cuts short.
 */
function decodeUtf8(bytes: Uint8Array, nullTerminated: unknown): string {
  const units: number[] = [];
  const end = bytes.length;
  let at = 0;
  while (at < end) {
    let u0 = bytes[at++]!;
    if (!(u0 & 128)) {
      if (nullTerminated && !u0) break;
      units.push(u0);
      continue;
    }
    if (at === end) break;
    const u1 = bytes[at++]! & 63;
    if ((u0 & 224) === 192) {
      units.push((((u0 & 31) << 6) | u1) & 0xffff);
      continue;
    }
    if (at === end) break;
    const u2 = bytes[at++]! & 63;
    if ((u0 & 240) === 224) {
      u0 = ((u0 & 15) << 12) | (u1 << 6) | u2;
    } else {
      if (at === end) break;
      u0 = ((u0 & 7) << 18) | (u1 << 12) | (u2 << 6) | (bytes[at++]! & 63);
    }
    if (u0 < 0x10000) {
      units.push(u0);
    } else {
      u0 -= 0x10000;
      units.push(((u0 >> 10) | 0xd800) & 0xffff, (u0 & 0x03ff) | 0xdc00);
    }
  }
  let text = "";
  for (let from = 0; from < units.length; from += 8192) text += String.fromCharCode(...units.slice(from, from + 8192));
  return text;
}

/** AssemblyScript's UTF-8 encoder in its default WTF-8 mode: a lone surrogate is three bytes. */
function encodeUtf8(text: string, nullTerminated: unknown): ArrayBuffer {
  const bytes: number[] = [];
  for (let at = 0; at < text.length; at++) {
    let c1 = text.charCodeAt(at);
    if (c1 < 128) {
      bytes.push(c1);
    } else if (c1 < 2048) {
      bytes.push((c1 >> 6) | 192, (c1 & 63) | 128);
    } else {
      const c2 = at + 1 < text.length ? text.charCodeAt(at + 1) : 0;
      if ((c1 & 0xfc00) === 0xd800 && (c2 & 0xfc00) === 0xdc00) {
        c1 = (0x10000 + ((c1 & 0x03ff) << 10)) | (c2 & 0x03ff);
        bytes.push((c1 >> 18) | 240, ((c1 >> 12) & 63) | 128, ((c1 >> 6) & 63) | 128, (c1 & 63) | 128);
        at++;
        continue;
      }
      bytes.push((c1 >> 12) | 224, ((c1 >> 6) & 63) | 128, (c1 & 63) | 128);
    }
  }
  if (nullTerminated) bytes.push(0);
  return new Uint8Array(bytes).buffer;
}

/**
 * The `String.UTF8` and `String.UTF16` namespaces of AssemblyScript's String,
 * which JavaScript's lacks. A pointer from `x.dataStart` stands in for the
 * `usize` the unsafe variants take.
 */
export const stringEncodings = {
  UTF8: {
    byteLength: (text: string, nullTerminated: unknown = false): number =>
      encodeUtf8(text, nullTerminated).byteLength,
    encode: (text: string, nullTerminated: unknown = false): ArrayBuffer => encodeUtf8(text, nullTerminated),
    decode: (buffer: unknown, nullTerminated: unknown = false): string =>
      decodeUtf8(bytesAt(buffer, "UTF8.decode"), nullTerminated),
    decodeUnsafe: (at: unknown, length: unknown, nullTerminated: unknown = false): string => {
      const p = pointer(at, "decode a string");
      return decodeUtf8(new Uint8Array(p.buffer, p.offset, number(length)), nullTerminated);
    },
  },
  UTF16: {
    byteLength: (text: string): number => text.length * 2,
    encode: (text: string): ArrayBuffer => {
      const view = new DataView(new ArrayBuffer(text.length * 2));
      for (let at = 0; at < text.length; at++) view.setUint16(at * 2, text.charCodeAt(at), true);
      return view.buffer;
    },
    decode: (buffer: unknown): string => {
      const bytes = bytesAt(buffer, "UTF16.decode");
      const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength & ~1);
      let text = "";
      for (let at = 0; at < view.byteLength; at += 2) text += String.fromCharCode(view.getUint16(at, true));
      return text;
    },
  },
};

/** The bit width of an integer builtin's operand: its type, or its value. */
function bitsOf(type: string, value: unknown): 16 | 32 | 64 {
  if (type === "u16" || type === "i16") return 16;
  if (type === "u64" || type === "i64") return 64;
  if (type) return 32;
  return typeof value === "bigint" ? 64 : 32;
}
const signed = (type: string) => type.startsWith("i");

const bswap = (value: unknown, type = ""): unknown => {
  const bits = bitsOf(type, value);
  if (bits === 64) {
    let rest = BigInt.asUintN(64, big(value));
    let out = 0n;
    for (let i = 0; i < 8; i++) {
      out = (out << 8n) | (rest & 0xffn);
      rest >>= 8n;
    }
    return signed(type) ? BigInt.asIntN(64, out) : out;
  }
  const v = number(value) >>> 0;
  if (bits === 16) {
    const swapped = ((v & 0xff) << 8) | ((v >>> 8) & 0xff);
    return signed(type) ? (swapped << 16) >> 16 : swapped;
  }
  const swapped = (((v & 0xff) << 24) | ((v & 0xff00) << 8) | ((v >>> 8) & 0xff00) | (v >>> 24)) >>> 0;
  return signed(type) ? swapped | 0 : swapped;
};

const rotate = (left: boolean) => (value: unknown, shift: unknown, type = ""): unknown => {
  const bits = bitsOf(type, value);
  if (bits === 64) {
    const v = BigInt.asUintN(64, big(value));
    const s = big(shift) & 63n;
    const out = BigInt.asUintN(64, left ? (v << s) | (v >> ((64n - s) & 63n)) : (v >> s) | (v << ((64n - s) & 63n)));
    return signed(type) ? BigInt.asIntN(64, out) : out;
  }
  const v = number(value) >>> 0;
  const s = number(shift) & 31;
  const out = (left ? (v << s) | (v >>> ((32 - s) & 31)) : (v >>> s) | (v << ((32 - s) & 31))) >>> 0;
  return signed(type) ? out | 0 : out;
};

const TYPED_ARRAYS: Record<string, new (length: number) => ArrayLike<number>> = {
  i8: Int8Array,
  u8: Uint8Array,
  i16: Int16Array,
  u16: Uint16Array,
  i32: Int32Array,
  u32: Uint32Array,
  f32: Float32Array,
  f64: Float64Array,
};

/** AssemblyScript's generic `min`/`max` builtins. */
export const builtinMin = (a: any, b: any) => (b < a ? b : a);
export const builtinMax = (a: any, b: any) => (b > a ? b : a);

const address = (value: unknown): unknown => {
  value = asNull(value);
  if (value === null || value === undefined) return 0;
  if (isBuffer(value)) return new Pointer(value, 0);
  if (typeof value === "number" || typeof value === "bigint") return value;
  if (typeof value === "boolean") return value ? 1 : 0;
  if (typeof value === "string") {
    if (stringAddresses.size > 100_000) stringAddresses.clear();
    let at = stringAddresses.get(value);
    if (at === undefined) stringAddresses.set(value, (at = nextAddress()));
    return at;
  }
  return objectAddress(value as object);
};

function objectAddress(value: object): number {
  let at = objectAddresses.get(value);
  if (at === undefined) objectAddresses.set(value, (at = nextAddress()));
  return at;
}

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
 * `x as i64` and `x as u64`: a bigint of that width. A number truncates toward
 * zero and an i32 sign-extends before the wrap, as `i64.extend_i32_s` and
 * `i64.trunc_f64_s` do; a reference, like `as i32`'s, is 0.
 */
const wrapTo64 = (signed: boolean) => (value: unknown): bigint => {
  let n: bigint;
  if (typeof value === "bigint") n = value;
  else if (typeof value === "number") n = Number.isFinite(value) ? BigInt(Math.trunc(value)) : 0n;
  else if (typeof value === "boolean") n = value ? 1n : 0n;
  else n = 0n;
  return signed ? BigInt.asIntN(64, n) : BigInt.asUintN(64, n);
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
 * AssemblyScript's default comparator (std/assembly/util/sort.ts COMPARATOR):
 * numbers by value, strings by code unit, and another reference by `a > b`
 * and `a < b` — graph-ts' BigInt and BigDecimal overload them. A reference
 * without the overload compares by address, its allocation order; here it
 * keeps its place, the order the array was built in.
 */
function defaultCompare(a: unknown, b: unknown): number {
  if (typeof a === "string" && typeof b === "string") return a < b ? -1 : a > b ? 1 : 0;
  const greater = isObject(b) ? overload(a, "gt") : undefined;
  const less = isObject(b) ? overload(a, "lt") : undefined;
  if (greater && less) return (greater.call(a, b) ? 1 : 0) - (less.call(a, b) ? 1 : 0);
  const numeric = (v: unknown) => typeof v === "number" || typeof v === "bigint" || typeof v === "boolean";
  if (numeric(a) && numeric(b)) return (a as number) > (b as number) ? 1 : (a as number) < (b as number) ? -1 : 0;
  return 0;
}

const sort = (receiver: any): unknown => (Array.isArray(receiver) ? receiver.sort(defaultCompare) : receiver.sort());

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
 * What a mapping can name on one of these besides a key: the class's own
 * members, and what Node and the runtime look up on any object.
 */
const NOT_KEYS = new Set(["then", "toJSON", "constructor", "valueOf", "toString", "inspect"]);

/**
 * A property access that stands for `[]` on AssemblyScript's Map or Set: the
 * key as the collection holds it, a number when its numeric spelling is one.
 */
function keyOf(target: Map<unknown, unknown> | Set<unknown>, prop: string): unknown {
  if (target.has(prop)) return prop;
  const number = Number(prop);
  if (prop !== "" && String(number) === prop && (target.has(number) || firstKeyIsNumber(target))) return number;
  return prop;
}

function firstKeyIsNumber(target: Map<unknown, unknown> | Set<unknown>): boolean {
  for (const key of target.keys()) return typeof key === "number";
  return false;
}

/**
 * Serves `collection[key]` and `collection[key] = value` through the class's
 * `[]` operators; its own members, bound to it, through everything else.
 */
function indexedBy<T extends Map<unknown, unknown> | Set<unknown>>(
  collection: T,
  read: (target: T, key: unknown) => unknown,
  write: (target: T, key: unknown, value: unknown) => void,
): T {
  const bound = new Map<PropertyKey, Function>();
  return new Proxy(collection, {
    get(target, prop) {
      if (typeof prop === "symbol" || prop in target || NOT_KEYS.has(prop)) {
        const value = Reflect.get(target, prop, target);
        if (typeof value !== "function") return value;
        let method = bound.get(prop);
        if (!method) bound.set(prop, (method = value.bind(target)));
        return method;
      }
      return read(target, keyOf(target, prop));
    },
    set(target, prop, value) {
      if (typeof prop === "symbol" || prop in target) return Reflect.set(target, prop, value, target);
      write(target, keyOf(target, prop), value);
      return true;
    },
  });
}

/**
 * AssemblyScript's `Map` (std/assembly/map.ts): `keys()` and `values()` are
 * arrays, `get` of a missing key throws, and `[]` reads and writes an entry.
 */
export class AsMap<K, V> extends Map<K, V> {
  constructor() {
    super();
    return indexedBy(
      this,
      (target, key) => target.get(key as K),
      (target, key, value) => target.set(key as K, value as V),
    );
  }
  get(key: K): V {
    if (!super.has(key)) throw new Error("Key does not exist");
    return super.get(key) as V;
  }
  keys(): any {
    return Array.from(super.keys());
  }
  values(): any {
    return Array.from(super.values());
  }
}

/**
 * AssemblyScript's `Set` (std/assembly/set.ts): `values()` is an array, `[]`
 * reads `has`, and `set[key] = flag` adds or deletes.
 */
export class AsSet<T> extends Set<T> {
  constructor() {
    super();
    return indexedBy(
      this,
      (target, key) => target.has(key as T),
      (target, key, value) => (value ? target.add(key as T) : target.delete(key as T)),
    );
  }
  values(): any {
    return Array.from(super.values());
  }
}

const add = binary("plus", widened((a, b) => a + b));
const sub = binary("minus", widened((a, b) => a - b));

/**
 * graph-ts overloads the arithmetic and comparison operators on `BigInt`,
 * `BigDecimal` and `ByteArray`, and AssemblyScript calls the overload: a
 * JavaScript operator would coerce them, or compare their identity — so
 * `address == ZERO_ADDRESS` would always be false.
 */
export const operators = {
  recv: (receiver: any): any => receiver ?? nullReceiver,
  add: (a: unknown, b: unknown): unknown =>
    a instanceof Pointer ? a.at(number(b)) : b instanceof Pointer ? b.at(number(a)) : add(a, b),
  sub: (a: unknown, b: unknown): unknown =>
    a instanceof Pointer
      ? b instanceof Pointer
        ? a.offset - b.offset
        : a.at(-number(b))
      : sub(a, b),
  load: (type: string, at: unknown, offset: unknown = 0): unknown => {
    const p = pointer(at, `load a ${type}`);
    return width(type).get(new DataView(p.buffer), p.offset + number(offset));
  },
  store: (type: string, at: unknown, value: unknown, offset: unknown = 0): void => {
    const p = pointer(at, `store a ${type}`);
    width(type).set(new DataView(p.buffer), p.offset + number(offset), value);
  },
  static_array: (element: string, length: unknown): unknown => new TYPED_ARRAYS[element](number(length)),
  null_object: nullObject,
  // `reinterpret<T>(x)`: x's bits as a T of x's width, the other of the pair
  // (std/assembly/builtins.ts: f32 <-> i32/u32, f64 <-> i64/u64).
  reinterpret: (type: string, value: unknown): unknown => {
    const view = new DataView(new ArrayBuffer(8));
    const from = { f32: "i32", f64: "i64", i32: "f32", u32: "f32", i64: "f64", u64: "f64" }[type];
    if (!from) throw new Error(`Envio Subgraph can't reinterpret a value as a ${type}: only between floats and integers of one width.`);
    width(from).set(view, 0, value);
    return width(type).get(view, 0);
  },
  bswap,
  rotl: rotate(true),
  rotr: rotate(false),
  mul: binary("times", widened((a, b) => a * b)),
  div: binary("div", integerDivision),
  // A division the source types as a float's, whole numbers or not.
  fdiv: binary("div", (a, b) => number(a) / number(b)),
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
  address,
  lt: binary("lt", (a, b) => a < b),
  le: binary("le", (a, b) => a <= b),
  gt: binary("gt", (a, b) => a > b),
  ge: binary("ge", (a, b) => a >= b),
  band: bits64((a, b) => a & b, (a, b) => a & b),
  bor: bits64((a, b) => a | b, (a, b) => a | b),
  bxor: bits64((a, b) => a ^ b, (a, b) => a ^ b),
  shl: bits64((a, b) => wrap64(a, a << (b & 63n)), (a, b) => a << b),
  shr: bits64((a, b) => a >> (b & 63n), (a, b) => a >> b),
  ushr: bits64((a, b) => BigInt.asUintN(64, a) >> (b & 63n), (a, b) => a >>> b),
  // A u32's bit operations, which AssemblyScript keeps unsigned.
  shl_u32: (a: unknown, b: unknown) => (Number(a) << Number(b)) >>> 0,
  shr_u32: (a: unknown, b: unknown) => Number(a) >>> Number(b),
  or_u32: (a: unknown, b: unknown) => (Number(a) | Number(b)) >>> 0,
  and_u32: (a: unknown, b: unknown) => (Number(a) & Number(b)) >>> 0,
  xor_u32: (a: unknown, b: unknown) => (Number(a) ^ Number(b)) >>> 0,
  as_i8: wrapTo(8, true),
  as_u8: wrapTo(8, false),
  as_i16: wrapTo(16, true),
  as_u16: wrapTo(16, false),
  as_i32: wrapTo(32, true),
  as_u32: wrapTo(32, false),
  // AssemblyScript's dtoa writes what JavaScript does, but a whole number
  // with ".0" (JavaScript already writes -0 as "0").
  ftoa: (value: unknown): string => {
    const text = String(isObject(value) ? value : number(value));
    return /^-?\d+$/.test(text) ? `${text}.0` : text;
  },
  as_i64: wrapTo64(true),
  as_u64: wrapTo64(false),
  as_f64: (value: unknown): unknown => (isObject(value) ? value : number(value ?? 0)),
  as_f32: (value: unknown): unknown => (isObject(value) ? value : Math.fround(number(value ?? 0))),
  neg: (a: unknown) => {
    const declared = overload(a, "neg");
    return declared ? declared.call(a) : -(a as number);
  },
  sort,
  indexOf: search("indexOf"),
  lastIndexOf: search("lastIndexOf"),
  includes: search("includes"),
};
