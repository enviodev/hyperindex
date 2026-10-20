/**
 * What `@graphprotocol/graph-ts` resolves to at runtime inside a subgraph
 * project. Types still resolve to the real package, so the editor and `tsc`
 * see exactly what a subgraph developer sees today; only module resolution is
 * swapped, and only for the mapping graph.
 *
 * Everything `graph codegen` emits sits on this surface — entity classes over
 * `Entity`/`TypedMap`/`Value` and `store`, contract bindings over
 * `ethereum.SmartContract`, template classes over `DataSourceTemplate` — so
 * the project's real `generated/` runs on top of it unchanged.
 */

import { appendFileSync, mkdirSync, readFileSync } from "node:fs";
import path from "node:path";
import BigNumber from "bignumber.js";
import { type Document, isAlias, isMap, isScalar, isSeq, parseDocument } from "yaml";
import type * as GraphTsTypes from "./graph-ts-types/index.js";
import * as GraphNodeDecimal from "./graph-node-decimal.ts";
import {
  keccak256 as viemKeccak256,
  toHex,
  hexToBytes,
  decodeAbiParameters,
  parseAbiParameters,
} from "viem";
import { subgraphKeccak256 } from "../Core.res.mjs";
import { warn } from "../Logging.res.mjs";
import { operators } from "./assemblyscript.ts";
import { currentScope, type Scope } from "./scope.ts";
import { timeseriesId } from "./rollup.ts";
import { Level as LogLevel, ValueKind as EthereumValueKind } from "./graph-ts-enums.ts";
import { parseSignature, splitTypes } from "./abi-types.ts";
import {
  PROTOTYPE_PASSTHROUGH,
  strictNamespace,
  unsupported,
  unknown,
} from "./errors.ts";

// ---------------------------------------------------------------------------
// Byte values
// ---------------------------------------------------------------------------

/**
 * graph-ts stores every integer as a little-endian byte array, signed values in
 * two's complement — so the byte order and the sign both have to be spelled out
 * here rather than borrowed from a hex string, which reads big-endian.
 */
/** An AssemblyScript i64 literal reaches the shim as a plain JS number. */
function asBigInt(value: bigint | number): bigint {
  return typeof value === "bigint" ? value : BigInt(Math.trunc(value));
}

function toLittleEndian(value: bigint, size: number): Uint8Array {
  const out = new Uint8Array(size);
  let rest = BigInt.asUintN(size * 8, value);
  for (let index = 0; index < size; index++) {
    out[index] = Number(rest & 0xffn);
    rest >>= 8n;
  }
  return out;
}

function fromLittleEndian(bytes: Uint8Array, signed: boolean): bigint {
  let magnitude = 0n;
  for (let index = bytes.length - 1; index >= 0; index--) {
    magnitude = (magnitude << 8n) | BigInt(bytes[index]);
  }
  return signed ? BigInt.asIntN(bytes.length * 8, magnitude) : magnitude;
}

/** The smallest byte count that still holds `value` in two's complement. */
function byteWidth(value: bigint): number {
  let size = 1;
  while (BigInt.asIntN(size * 8, value) !== value) size++;
  return size;
}

/**
 * graph-ts' `BigInt.toU32()`/`toU64()`: the minimal two's-complement
 * little-endian bytes, zero-padded to the width — so -1 (the byte 0xff) is
 * 255 — overflowing only when a byte past the width is set.
 */
function unsignedFromSignedBytes(value: bigint, size: number, target: string): bigint {
  if (value >= 0n) return fitted(value, 0n, (1n << BigInt(size * 8)) - 1n, target);
  const width = byteWidth(value);
  if (width > size) {
    throw new Error(`Envio Subgraph: ${value} does not fit in an ${target}.`);
  }
  return BigInt.asUintN(width * 8, value);
}

function fitted(value: bigint, min: bigint, max: bigint, target: string): bigint {
  if (value < min || value > max) {
    throw new Error(`Envio Subgraph: ${value} does not fit in an ${target}.`);
  }
  return value;
}

const utf8Decoder = new TextDecoder("utf-8");

const BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

function toBase58(bytes: Uint8Array): string {
  let zeros = 0;
  while (zeros < bytes.length && bytes[zeros] === 0) zeros++;
  // Repeated division of the big-endian number by 58, in base 256.
  const digits: number[] = [];
  for (let index = zeros; index < bytes.length; index++) {
    let carry = bytes[index];
    for (let digit = 0; digit < digits.length; digit++) {
      carry += digits[digit] << 8;
      digits[digit] = carry % 58;
      carry = Math.floor(carry / 58);
    }
    while (carry > 0) {
      digits.push(carry % 58);
      carry = Math.floor(carry / 58);
    }
  }
  let out = "1".repeat(zeros);
  for (let digit = digits.length - 1; digit >= 0; digit--) out += BASE58_ALPHABET[digits[digit]];
  return out;
}

/** `I8.parseInt(pair, 16)` as AssemblyScript reads it, kept to a byte. */
function parseHexPair(pair: string): number {
  let at = 0;
  let sign = 1;
  if (pair[0] === "-" || pair[0] === "+") {
    sign = pair[0] === "-" ? -1 : 1;
    at = 1;
  }
  let value = 0;
  for (; at < pair.length; at++) {
    const digit = parseInt(pair[at], 16);
    if (Number.isNaN(digit)) break;
    value = value * 16 + digit;
  }
  return (sign * value) & 0xff;
}

export class ByteArray extends Uint8Array {
  static fromHexString(hex: string): ByteArray {
    // graph-ts asserts on the whole string, strips one `0x`, then reads each
    // pair with `I8.parseInt(pair, 16)`, which stops at the first character
    // that isn't a hex digit: Croc pads "0x00000000" on the left with `0`s and
    // the pair that holds the `x` reads as 0.
    if (hex.length % 2 !== 0) throw new Error(`input ${hex} has odd length`);
    const digits = hex.startsWith("0x") ? hex.slice(2) : hex;
    const bytes = new Uint8Array(digits.length / 2);
    for (let i = 0; i < bytes.length; i++) bytes[i] = parseHexPair(digits.slice(2 * i, 2 * i + 2));
    return new ByteArray(bytes);
  }
  static fromUTF8(input: string): ByteArray {
    return new ByteArray(new TextEncoder().encode(input));
  }
  static fromI32(value: number): ByteArray {
    return new ByteArray(toLittleEndian(BigInt(Math.trunc(value)), 4));
  }
  static fromBigInt(value: BigInt_): ByteArray {
    return new ByteArray(toLittleEndian(value.valueOf() as bigint, value.byteLength));
  }
  static fromUint8Array(bytes: Uint8Array): ByteArray {
    return new ByteArray(bytes);
  }
  static fromU32(value: number): ByteArray {
    return ByteArray.fromI32(value);
  }
  static fromI64(value: bigint | number): ByteArray {
    return new ByteArray(toLittleEndian(asBigInt(value), 8));
  }
  static fromU64(value: bigint): ByteArray {
    return ByteArray.fromI64(value);
  }
  static empty(): ByteArray {
    return new ByteArray(0);
  }
  toHex(): string {
    return this.toHexString();
  }
  toHexString(): string {
    return toHex(this as Uint8Array);
  }
  /**
   * graph-node's `bytes_to_string`: UTF-8, invalid sequences replaced, and the
   * trailing NULs of a fixed-size buffer trimmed — a bytes32 symbol (MKR) reads
   * as `MKR`, and Aave's `id.toString() == "POOL"` holds.
   */
  toString(): string {
    return utf8Decoder.decode(this).replace(/\u0000+$/, "");
  }
  /**
   * graph-node's `bytes_to_base58`: Bitcoin-alphabet base58, each leading zero
   * byte a leading `1`. Turns a bytes32 digest behind a `Qm` prefix into the
   * CID a subgraph hands to `ipfs.cat` or a file data source.
   */
  toBase58(): string {
    return toBase58(this);
  }
  toU32(): number {
    return Number(fitted(fromLittleEndian(this, false), 0n, 4294967295n, "u32"));
  }
  toI32(): number {
    return Number(fitted(fromLittleEndian(this, true), -2147483648n, 2147483647n, "i32"));
  }
  toBigInt(): BigInt_ {
    return new BigInt_(fromLittleEndian(this, true));
  }
  concat(other: ByteArray): ByteArray {
    const out = new ByteArray(this.length + other.length);
    out.set(this, 0);
    out.set(other, this.length);
    return out;
  }
  equals(other: ByteArray): boolean {
    return this.toHexString() === other.toHexString();
  }
  notEqual(other: ByteArray): boolean {
    return !this.equals(other);
  }
  concatI32(other: number): ByteArray {
    return this.concat(ByteArray.fromI32(other));
  }
  toI64(): bigint {
    return fitted(fromLittleEndian(this, true), -(2n ** 63n), 2n ** 63n - 1n, "i64");
  }
  toU64(): bigint {
    return fitted(fromLittleEndian(this, false), 0n, 2n ** 64n - 1n, "u64");
  }
}

export class Bytes extends ByteArray {
  static fromHexString(hex: string): Bytes {
    return new Bytes(ByteArray.fromHexString(hex));
  }
  static fromUTF8(input: string): Bytes {
    return new Bytes(ByteArray.fromUTF8(input));
  }
  static fromByteArray(byteArray: ByteArray): Bytes {
    return new Bytes(byteArray);
  }
  static fromI32(value: number): Bytes {
    return new Bytes(ByteArray.fromI32(value));
  }
  static fromUint8Array(bytes: Uint8Array): Bytes {
    return new Bytes(bytes);
  }
  static fromU32(value: number): Bytes {
    return new Bytes(ByteArray.fromU32(value));
  }
  static fromI64(value: bigint): Bytes {
    return new Bytes(ByteArray.fromI64(value));
  }
  static fromU64(value: bigint): Bytes {
    return new Bytes(ByteArray.fromU64(value));
  }
  static fromBigInt(value: BigInt_): Bytes {
    return new Bytes(ByteArray.fromBigInt(value));
  }
  static empty(): Bytes {
    return new Bytes(0);
  }
}

export class Address extends Bytes {
  static fromString(address: string): Address {
    // graph-node's `string_to_h160` trims a leading `0x` and parses the rest,
    // so the prefix is optional (Livepeer's constants are bare hex).
    if (!/^(0x)?[0-9a-fA-F]{40}$/.test(address)) {
      throw new Error(`Address.fromString: ${address} is not a valid 20-byte hex address`);
    }
    return new Address(ByteArray.fromHexString((address.startsWith("0x") ? address : "0x" + address).toLowerCase()));
  }
  static fromBytes(bytes: Bytes): Address {
    if (bytes.length !== 20) {
      throw new Error(
        `Envio Subgraph: Address.fromBytes needs 20 bytes, got ${bytes.length}.`,
      );
    }
    return new Address(bytes);
  }
  static zero(): Address {
    return Address.fromString("0x0000000000000000000000000000000000000000");
  }
  // graph-ts renders addresses lowercase, and id/derived-key parity across the
  // two indexers depends on it.
  toHexString(): string {
    return super.toHexString().toLowerCase();
  }
}

// ---------------------------------------------------------------------------
// Numbers
// ---------------------------------------------------------------------------

/**
 * Below apiVersion 0.0.5 graph-node reads a null operand handed to a host
 * function as an empty value, so `x.plus(null)` is `x`. From 0.0.5 it traps,
 * which is a TypeError here.
 */
let legacyNullOperands = false;

export function setLegacyNullOperands(on: boolean) {
  legacyNullOperands = on;
}

function operandOf(other: BigInt_): bigint {
  return legacyNullOperands && (other === null || other === undefined) ? 0n : other.value;
}

function decimalOperandOf(other: BigDecimal): GraphNodeDecimal.Decimal {
  return legacyNullOperands && (other === null || other === undefined)
    ? BigDecimal.zero().decimal
    : other.decimal;
}

class BigInt_ extends Uint8Array {
  readonly value: bigint;
  /**
   * How many bytes graph-ts holds this value in. A BigInt IS its bytes there,
   * and the count depends on how it was made: `fromI32` keeps the i32's four,
   * `fromU32` five (a sign byte follows the unsigned ones), `fromI64` eight,
   * `fromU64` nine; whatever comes from an event or arithmetic is graph-node's
   * minimal two's complement. Unset means minimal.
   */
  width?: number;

  // `new BigInt(0)` is AssemblyScript's other spelling of zero: the class is a
  // Uint8Array and the argument its byte length, so a mapping that passes a
  // number gets that many zero bytes — zero, whatever the length.
  constructor(value: bigint | number) {
    // The bytes are deliberately left empty. Arithmetic, comparison and every
    // `to*` run off `value`; materialising the two's-complement representation
    // on construction cost ~7% of indexing CPU, and nothing in a mapping reads
    // a BigInt as bytes — graph codegen never emits it, and the conversions
    // that would (`toHexString`, `toI32`) are overridden here.
    super(0);
    this.value = typeof value === "bigint" ? value : 0n;
  }

  // Inherited TypedArray operations (`map`, `slice`, `subarray`) would
  // otherwise call this constructor with a length.
  static get [Symbol.species](): Uint8ArrayConstructor {
    return Uint8Array;
  }

  // graph codegen types a small uint as `i32`, so a mapping hands one straight
  // to `fromI32` — but envio decodes every integer ABI type as a bigint, so what
  // arrives is already a BigInt.
  static fromI32(value: number | bigint | BigInt_): BigInt_ {
    const raw = typeof value === "object" ? (value as BigInt_).valueOf() : value;
    if (typeof raw !== "bigint") {
      const made = new BigInt_(BigInt(Math.trunc(raw as number)));
      made.width = 4;
      return made;
    }
    return BigInt_.withWidth(raw, 4);
  }
  // A u32 parameter: the bits of whatever 32-bit integer the mapping passed.
  static fromU32(value: number): BigInt_ {
    const made = new BigInt_(BigInt(Math.trunc(value) >>> 0));
    made.width = 5;
    return made;
  }
  static fromI64(value: bigint | number): BigInt_ {
    return BigInt_.withWidth(BigInt(value), 8);
  }
  static fromU64(value: bigint | number): BigInt_ {
    return BigInt_.withWidth(BigInt(value), 9);
  }
  private static withWidth(value: bigint, width: number): BigInt_ {
    const made = new BigInt_(value);
    made.width = Math.max(width, byteWidth(value));
    return made;
  }
  /** The byte count graph-ts reports (see `width`). */
  get byteLength(): number {
    return this.width ?? byteWidth(this.value);
  }
  get length(): number {
    return this.byteLength;
  }
  static fromString(value: string): BigInt_ {
    return new BigInt_(BigInt(value));
  }
  static fromByteArray(bytes: ByteArray): BigInt_ {
    return BigInt_.fromSignedBytes(bytes as Bytes);
  }
  static fromUnsignedBytes(bytes: ByteArray): BigInt_ {
    const value = fromLittleEndian(bytes, false);
    return BigInt_.withWidth(value, bytes.length + 1);
  }
  static fromSignedBytes(bytes: Bytes): BigInt_ {
    const value = fromLittleEndian(bytes, true);
    return BigInt_.withWidth(value, bytes.length);
  }
  static zero(): BigInt_ {
    return BigInt_.fromI32(0);
  }
  static compare(a: BigInt_, b: BigInt_): number {
    return a.value < b.value ? -1 : a.value > b.value ? 1 : 0;
  }

  // Uint8Array.valueOf returns the array itself; graph-ts BigInt has no
  // valueOf at all, so widening keeps both callers honest.
  valueOf(): any {
    return this.value;
  }
  toString(): string {
    return this.value.toString();
  }
  toHex(): string {
    return this.toHexString();
  }
  toHexString(): string {
    return toHex(this.value);
  }
  toI32(): number {
    return Number(fitted(this.value, -2147483648n, 2147483647n, "i32"));
  }
  toU32(): number {
    return Number(unsignedFromSignedBytes(this.value, 4, "u32"));
  }
  toI64(): bigint {
    return this.value;
  }
  toBigDecimal(): BigDecimal {
    return new BigDecimal(new BigNumber(this.value.toString()));
  }

  plus(other: BigInt_): BigInt_ {
    return new BigInt_(this.value + operandOf(other));
  }
  minus(other: BigInt_): BigInt_ {
    return new BigInt_(this.value - operandOf(other));
  }
  times(other: BigInt_): BigInt_ {
    return new BigInt_(this.value * operandOf(other));
  }
  div(other: BigInt_): BigInt_ {
    return new BigInt_(this.value / operandOf(other));
  }
  mod(other: BigInt_): BigInt_ {
    return new BigInt_(this.value % operandOf(other));
  }
  pow(exponent: number): BigInt_ {
    return new BigInt_(this.value ** BigInt(exponent));
  }
  neg(): BigInt_ {
    return new BigInt_(-this.value);
  }
  abs(): BigInt_ {
    return new BigInt_(this.value < 0n ? -this.value : this.value);
  }
  equals(other: BigInt_): boolean {
    return this.value === operandOf(other);
  }
  notEqual(other: BigInt_): boolean {
    return this.value !== operandOf(other);
  }
  lt(other: BigInt_): boolean {
    return this.value < operandOf(other);
  }
  le(other: BigInt_): boolean {
    return this.value <= operandOf(other);
  }
  gt(other: BigInt_): boolean {
    return this.value > operandOf(other);
  }
  ge(other: BigInt_): boolean {
    return this.value >= operandOf(other);
  }
  isZero(): boolean {
    return this.value === 0n;
  }
  isI32(): boolean {
    return this.value >= -2147483648n && this.value <= 2147483647n;
  }
  toU64(): bigint {
    return unsignedFromSignedBytes(this.value, 8, "u64");
  }
  sqrt(): BigInt_ {
    if (this.value < 0n) {
      throw new Error("BigInt.sqrt of a negative value");
    }
    let guess = this.value;
    let next = (guess + 1n) / 2n;
    while (next < guess) {
      guess = next;
      next = (guess + this.value / guess) / 2n;
    }
    return new BigInt_(guess);
  }
  divDecimal(other: BigDecimal): BigDecimal {
    return this.toBigDecimal().div(other);
  }
  bitAnd(other: BigInt_): BigInt_ {
    return new BigInt_(this.value & other.value);
  }
  bitOr(other: BigInt_): BigInt_ {
    return new BigInt_(this.value | other.value);
  }
  leftShift(bits: number): BigInt_ {
    return new BigInt_(this.value << BigInt(bits));
  }
  rightShift(bits: number): BigInt_ {
    return new BigInt_(this.value >> BigInt(bits));
  }
}

export { BigInt_ as BigInt };

/**
 * Carried by each BigNumber `value` handed to envio's store: the decimal it was
 * made from, so an entity read back from memory isn't printed and parsed again.
 */
const DECIMAL = Symbol("envio.subgraph.decimal");

/** Mappings parse the same few literals over and over: `"1"`, `"10"`, `"0"`. */
const parsedDecimals = new Map<string, GraphNodeDecimal.Decimal>();

function parseDecimal(text: string): GraphNodeDecimal.Decimal {
  let decimal = parsedDecimals.get(text);
  if (decimal === undefined) {
    decimal = GraphNodeDecimal.parse(text);
    if (parsedDecimals.size >= 1024) parsedDecimals.clear();
    parsedDecimals.set(text, decimal);
  }
  return decimal;
}

/**
 * Every value is held as graph-node holds it: normalized to 34 significant
 * digits by `graph-node-decimal` after every operation, and once more as it
 * would be crossing back into graph-node's host (`BigDecimal::new`), which is
 * what a later operation, `toString` or the store sees. `value` is the same
 * number for envio's store, made only when something asks for it.
 */
export class BigDecimal {
  readonly decimal: GraphNodeDecimal.Decimal;
  private _value: BigNumber | undefined;

  constructor(value: GraphNodeDecimal.Decimal | BigNumber | BigInt_ | string | number) {
    this.decimal =
      value instanceof BigInt_
        ? GraphNodeDecimal.fromInteger(value.value)
        : value instanceof BigNumber
          ? ((value as BigNumber & { [DECIMAL]?: GraphNodeDecimal.Decimal })[DECIMAL] ??
            GraphNodeDecimal.parse(value.toFixed()))
          : typeof value === "object"
            ? GraphNodeDecimal.normalize(value)
            : parseDecimal(String(value));
  }

  get value(): BigNumber {
    if (this._value === undefined) {
      const value = new BigNumber(GraphNodeDecimal.format(this.decimal));
      (value as BigNumber & { [DECIMAL]?: GraphNodeDecimal.Decimal })[DECIMAL] = this.decimal;
      this._value = value;
    }
    return this._value;
  }

  static fromString(value: string): BigDecimal {
    return new BigDecimal(value);
  }
  static zero(): BigDecimal {
    return new BigDecimal(0);
  }
  static compare(a: BigDecimal, b: BigDecimal): number {
    return GraphNodeDecimal.compare(a.decimal, b.decimal);
  }

  toString(): string {
    return GraphNodeDecimal.format(this.decimal);
  }
  toBigInt(): BigInt_ {
    return BigInt_.fromString(this.value.integerValue(BigNumber.ROUND_DOWN).toFixed());
  }
  plus(other: BigDecimal): BigDecimal {
    return new BigDecimal(GraphNodeDecimal.add(this.decimal, decimalOperandOf(other)));
  }
  minus(other: BigDecimal): BigDecimal {
    return new BigDecimal(GraphNodeDecimal.subtract(this.decimal, decimalOperandOf(other)));
  }
  times(other: BigDecimal): BigDecimal {
    return new BigDecimal(GraphNodeDecimal.multiply(this.decimal, decimalOperandOf(other)));
  }
  div(other: BigDecimal): BigDecimal {
    return new BigDecimal(GraphNodeDecimal.divide(this.decimal, decimalOperandOf(other)));
  }
  equals(other: BigDecimal): boolean {
    return GraphNodeDecimal.compare(this.decimal, decimalOperandOf(other)) === 0;
  }
  notEqual(other: BigDecimal): boolean {
    return GraphNodeDecimal.compare(this.decimal, decimalOperandOf(other)) !== 0;
  }
  lt(other: BigDecimal): boolean {
    return GraphNodeDecimal.compare(this.decimal, decimalOperandOf(other)) < 0;
  }
  le(other: BigDecimal): boolean {
    return GraphNodeDecimal.compare(this.decimal, decimalOperandOf(other)) <= 0;
  }
  gt(other: BigDecimal): boolean {
    return GraphNodeDecimal.compare(this.decimal, decimalOperandOf(other)) > 0;
  }
  ge(other: BigDecimal): boolean {
    return GraphNodeDecimal.compare(this.decimal, decimalOperandOf(other)) >= 0;
  }
  // graph-ts negates by subtracting from zero, which normalizes like any other
  // operation.
  neg(): BigDecimal {
    return BigDecimal.zero().minus(this);
  }
  truncate(decimals: number): BigDecimal {
    return new BigDecimal(this.value.decimalPlaces(decimals, BigNumber.ROUND_DOWN));
  }
  // graph-ts stores a decimal as `digits * 10 ** exp`, in graph-node's
  // normalized form.
  get digits(): BigInt_ {
    return new BigInt_(this.decimal.int);
  }
  get exp(): BigInt_ {
    return BigInt_.fromI32(-this.decimal.scale);
  }
}

// ---------------------------------------------------------------------------
// TypedMap / Value / Entity
// ---------------------------------------------------------------------------

export class Wrapped<T> {
  constructor(public inner: T) {}
}

export class Result<V, E> {
  constructor(
    public _value: Wrapped<V> | null = null,
    public _error: Wrapped<E> | null = null,
  ) {}
  get isOk(): boolean {
    return this._value !== null;
  }
  get isError(): boolean {
    return this._error !== null;
  }
  get value(): V {
    if (this._value === null) throw new Error("Trying to get a value from an error result");
    return this._value.inner;
  }
  get error(): E {
    if (this._error === null) throw new Error("Trying to get an error from a successful result");
    return this._error.inner;
  }
}

function tryParse<V>(parse: () => V): Result<V, boolean> {
  try {
    return new Result(new Wrapped(parse()));
  } catch {
    return new Result<V, boolean>(null, new Wrapped(true));
  }
}

export class TypedMapEntry<K, V> {
  constructor(
    public key: K,
    public value: V,
  ) {}
}

// The map's storage. graph-ts' `TypedMap.entries` is a plain field, and the
// class graph codegen writes for an entity with a field called `entries`
// overrides it with an accessor: AssemblyScript's own methods keep reading the
// field, while a mapping's `rs.entries = []` reaches the accessor. A JavaScript
// field would be overwritten by that assignment, wiping the entity's id.
const MAP_ENTRIES = Symbol("envio.subgraph.typedMapEntries");

function entriesOf<K, V>(map: TypedMap<K, V>): TypedMapEntry<K, V>[] {
  return (map as any)[MAP_ENTRIES];
}

/**
 * AssemblyScript's `==` on a `Bytes`, `BigInt` or `BigDecimal` key compares the
 * values, which is how Lido looks a log's topic up in a `TypedMap<Bytes, …>`
 * built from other `Bytes` instances.
 */
function sameKey(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a === "object" && a !== null && typeof b === "object" && b !== null) {
    const equals = (a as { equals?: (other: unknown) => unknown }).equals;
    if (typeof equals === "function" && a instanceof Uint8Array === b instanceof Uint8Array) {
      return equals.call(a, b) === true;
    }
  }
  return false;
}

export class TypedMap<K, V> {
  constructor() {
    Object.defineProperty(this, MAP_ENTRIES, { value: [], writable: true });
  }

  get entries(): TypedMapEntry<K, V>[] {
    return entriesOf(this);
  }
  set entries(value: TypedMapEntry<K, V>[]) {
    (this as any)[MAP_ENTRIES] = value;
  }

  set(key: K, value: V): void {
    const entry = this.getEntry(key);
    if (entry) {
      entry.value = value;
    } else {
      entriesOf(this).push(new TypedMapEntry(key, value));
    }
  }
  getEntry(key: K): TypedMapEntry<K, V> | null {
    const entries = entriesOf(this);
    for (let index = 0; index < entries.length; index++) {
      if (sameKey(entries[index].key, key)) return entries[index];
    }
    return null;
  }
  get(key: K): V | null {
    const entry = this.getEntry(key);
    return entry ? entry.value : null;
  }
  mustGetEntry(key: K): TypedMapEntry<K, V> {
    const entry = this.getEntry(key);
    if (entry === null) {
      throw new Error(`TypedMap does not contain an entry for key ${String(key)}`);
    }
    return entry;
  }
  mustGet(key: K): V {
    const value = this.get(key);
    if (value === null) {
      throw new Error(`TypedMap does not contain a value for key ${String(key)}`);
    }
    return value;
  }
  isSet(key: K): boolean {
    return this.getEntry(key) !== null;
  }
}

export enum ValueKind {
  STRING = 0,
  INT = 1,
  BIGDECIMAL = 2,
  BOOL = 3,
  ARRAY = 4,
  NULL = 5,
  BYTES = 6,
  BIGINT = 7,
  INT8 = 8,
  TIMESTAMP = 9,
}

export class Value {
  constructor(
    public kind: ValueKind,
    public data: any,
  ) {}

  static fromString(value: string): Value {
    return new Value(ValueKind.STRING, value);
  }
  static fromI32(value: number): Value {
    return new Value(ValueKind.INT, value);
  }
  static fromI64(value: bigint): Value {
    return new Value(ValueKind.INT8, value);
  }
  static fromBigInt(value: BigInt_): Value {
    return new Value(ValueKind.BIGINT, value);
  }
  static fromBigDecimal(value: BigDecimal): Value {
    return new Value(ValueKind.BIGDECIMAL, value);
  }
  static fromBoolean(value: boolean): Value {
    return new Value(ValueKind.BOOL, value);
  }
  static fromBytes(value: Bytes): Value {
    return new Value(ValueKind.BYTES, value);
  }
  static fromAddress(value: Address): Value {
    return new Value(ValueKind.BYTES, value);
  }
  static fromTimestamp(value: bigint): Value {
    return new Value(ValueKind.TIMESTAMP, value);
  }
  static fromNull(): Value {
    return new Value(ValueKind.NULL, null);
  }
  static fromArray(values: Value[]): Value {
    return new Value(ValueKind.ARRAY, values);
  }
  static fromStringArray(values: string[]): Value {
    return Value.fromArray(values.map(Value.fromString));
  }
  static fromBytesArray(values: Bytes[]): Value {
    return Value.fromArray(values.map(Value.fromBytes));
  }
  static fromBigIntArray(values: BigInt_[]): Value {
    return Value.fromArray(values.map(Value.fromBigInt));
  }
  static fromBigDecimalArray(values: BigDecimal[]): Value {
    return Value.fromArray(values.map(Value.fromBigDecimal));
  }
  static fromBooleanArray(values: boolean[]): Value {
    return Value.fromArray(values.map(Value.fromBoolean));
  }
  static fromI32Array(values: number[]): Value {
    return Value.fromArray(values.map(Value.fromI32));
  }
  static fromI64Array(values: bigint[]): Value {
    return Value.fromArray(values.map(Value.fromI64));
  }
  static fromAddressArray(values: Address[]): Value {
    return Value.fromArray(values.map(Value.fromAddress));
  }
  static fromMatrix(values: Value[][]): Value {
    return Value.fromArray(values.map(Value.fromArray));
  }
  static fromStringMatrix(values: string[][]): Value {
    return Value.fromMatrix(values.map((row) => row.map(Value.fromString)));
  }
  static fromBytesMatrix(values: Bytes[][]): Value {
    return Value.fromMatrix(values.map((row) => row.map(Value.fromBytes)));
  }
  static fromAddressMatrix(values: Address[][]): Value {
    return Value.fromMatrix(values.map((row) => row.map(Value.fromAddress)));
  }
  static fromBigIntMatrix(values: BigInt_[][]): Value {
    return Value.fromMatrix(values.map((row) => row.map(Value.fromBigInt)));
  }
  static fromBooleanMatrix(values: boolean[][]): Value {
    return Value.fromMatrix(values.map((row) => row.map(Value.fromBoolean)));
  }
  static fromI32Matrix(values: number[][]): Value {
    return Value.fromMatrix(values.map((row) => row.map(Value.fromI32)));
  }
  static fromI64Matrix(values: bigint[][]): Value {
    return Value.fromMatrix(values.map((row) => row.map(Value.fromI64)));
  }
  static fromTimestampMatrix(values: bigint[][]): Value {
    return Value.fromMatrix(values.map((row) => row.map(Value.fromTimestamp)));
  }

  // The accessors are deliberately lenient about kind: envio stores a
  // subgraph's `Bytes` as lowercase hex text, so a value read back from the
  // store carries STRING where the generated getter asks for bytes.
  toString(): string {
    if (this.data instanceof Bytes || this.data instanceof ByteArray) {
      return this.data.toHexString();
    }
    return String(this.data);
  }
  toStringArray(): string[] {
    return (this.data as Value[]).map((value) => value.toString());
  }
  toBytes(): Bytes {
    if (this.data instanceof Bytes) return this.data;
    if (this.data instanceof ByteArray) return Bytes.fromByteArray(this.data);
    if (Array.isArray(this.data)) return pointerBytes(this.data);
    return Bytes.fromHexString(String(this.data));
  }
  toBytesArray(): Bytes[] {
    return (this.data as Value[]).map((value) => value.toBytes());
  }
  toAddress(): Address {
    return Address.fromString(this.toBytes().toHexString());
  }
  toBigInt(): BigInt_ {
    if (this.data instanceof BigInt_) return this.data;
    if (typeof this.data === "bigint") return new BigInt_(this.data);
    // `Value.fromBigInt(x!)` of a null `x` (a mapping asking an event for a
    // key it misspelt, GMX's "callbakGasLimit"): the `!` doesn't stop it in
    // graph-node, the Value carries a null pointer, and the BigInt behind it
    // reads as no bytes, i.e. 0.
    if (this.data == null) return BigInt_.zero();
    return BigInt_.fromString(String(this.data));
  }
  toBigIntArray(): BigInt_[] {
    return (this.data as Value[]).map((value) => value.toBigInt());
  }
  toBigDecimal(): BigDecimal {
    if (this.data instanceof BigDecimal) return this.data;
    return BigDecimal.fromString(String(this.data));
  }
  toBigDecimalArray(): BigDecimal[] {
    return (this.data as Value[]).map((value) => value.toBigDecimal());
  }
  toBoolean(): boolean {
    return Boolean(this.data);
  }
  toBooleanArray(): boolean[] {
    return (this.data as Value[]).map((value) => value.toBoolean());
  }
  toI32(): number {
    return Number(this.data);
  }
  toI32Array(): number[] {
    return (this.data as Value[]).map((value) => value.toI32());
  }
  toI64(): bigint {
    return BigInt(this.data as any);
  }
  toTimestamp(): bigint {
    return BigInt(this.data as any);
  }
  toArray(): Value[] {
    return this.data as Value[];
  }
  toMatrix(): Value[][] {
    return this.toArray().map((row) => row.toArray());
  }
  toI64Array(): bigint[] {
    return this.toArray().map((value) => value.toI64());
  }
  toTimestampArray(): bigint[] {
    return this.toArray().map((value) => value.toTimestamp());
  }
  toAddressMatrix(): Address[][] {
    return this.toMatrix().map((row) => row.map((value) => value.toAddress()));
  }
  toStringMatrix(): string[][] {
    return this.toMatrix().map((row) => row.map((value) => value.toString()));
  }
  toBytesMatrix(): Bytes[][] {
    return this.toMatrix().map((row) => row.map((value) => value.toBytes()));
  }
  toBigIntMatrix(): BigInt_[][] {
    return this.toMatrix().map((row) => row.map((value) => value.toBigInt()));
  }
  toBooleanMatrix(): boolean[][] {
    return this.toMatrix().map((row) => row.map((value) => value.toBoolean()));
  }
  toI32Matrix(): number[][] {
    return this.toMatrix().map((row) => row.map((value) => value.toI32()));
  }
  toI64Matrix(): bigint[][] {
    return this.toMatrix().map((row) => row.map((value) => value.toI64()));
  }
  displayData(): string {
    if (this.data instanceof ByteArray) return this.data.toHexString();
    return String(this.data);
  }
  displayKind(): string {
    return ValueKind[this.kind] ?? String(this.kind);
  }
}

/** A stored `Value` as the scalar a generated entity getter would return. */
function valueToNative(value: Value): unknown {
  switch (value.kind) {
    case ValueKind.NULL:
      return null;
    case ValueKind.BYTES:
      return value.toBytes();
    case ValueKind.BIGINT:
      return value.toBigInt();
    case ValueKind.BIGDECIMAL:
      return value.toBigDecimal();
    case ValueKind.INT8:
    case ValueKind.TIMESTAMP:
      return value.toI64();
    case ValueKind.ARRAY:
      return value.toArray().map(valueToNative);
    default:
      return value.data;
  }
}

function nativeToValue(native: unknown): Value {
  if (native === null || native === undefined) return Value.fromNull();
  if (native instanceof Value) return native;
  if (native instanceof Bytes || native instanceof ByteArray) {
    return Value.fromBytes(Bytes.fromByteArray(native));
  }
  if (native instanceof BigInt_) return Value.fromBigInt(native);
  if (native instanceof BigDecimal) return Value.fromBigDecimal(native);
  if (typeof native === "string") return Value.fromString(native);
  if (typeof native === "boolean") return Value.fromBoolean(native);
  if (typeof native === "bigint") return Value.fromI64(native);
  if (typeof native === "number") return Value.fromI32(native);
  if (Array.isArray(native)) return Value.fromArray(native.map(nativeToValue));
  return Value.fromString(String(native));
}

export class Entity extends TypedMap<string, Value> {
  setString(key: string, value: string): void {
    this.set(key, Value.fromString(value));
  }
  setI32(key: string, value: number): void {
    this.set(key, Value.fromI32(value));
  }
  setBigInt(key: string, value: BigInt_): void {
    this.set(key, Value.fromBigInt(value));
  }
  setBytes(key: string, value: Bytes): void {
    this.set(key, Value.fromBytes(value));
  }
  setBoolean(key: string, value: boolean): void {
    this.set(key, Value.fromBoolean(value));
  }
  setBigDecimal(key: string, value: BigDecimal): void {
    this.set(key, Value.fromBigDecimal(value));
  }
  getString(key: string): string {
    return this.mustGet(key).toString();
  }
  getI32(key: string): number {
    return this.mustGet(key).toI32();
  }
  getBigInt(key: string): BigInt_ {
    return this.mustGet(key).toBigInt();
  }
  getBytes(key: string): Bytes {
    return this.mustGet(key).toBytes();
  }
  getBoolean(key: string): boolean {
    return this.mustGet(key).toBoolean();
  }
  getBigDecimal(key: string): BigDecimal {
    return this.mustGet(key).toBigDecimal();
  }
  unset(key: string): void {
    this.set(key, Value.fromNull());
  }
  merge(sources: Entity[]): this {
    // graph-ts assigns each source in turn, so the last one wins a shared key.
    for (const source of sources) {
      for (const entry of entriesOf(source)) {
        this.set(entry.key, entry.value);
      }
    }
    return this;
  }
}

/**
 * Tail of the entity prototype chain: instance -> generated prototype ->
 * Entity -> TypedMap -> here.
 *
 * `graph codegen`'s `changetype<Pair | null>(store.get(...))` gives a loaded
 * entity the generated prototype, whose getters read its fields. An entity read
 * without one — `store.get` called directly, or cast to a class the file can't
 * reach — falls through to here, to the stored field typed by its `Value` kind.
 * A name the entity doesn't hold is still refused.
 */
/**
 * The entity type a loaded row came from. `changetype` erased the generated
 * prototype, and with it the `save()` that knows which table to write back to,
 * so the type is remembered on the instance instead.
 */
const ENTITY_TYPE = Symbol("envio.entityType");

/** An id as the store keys rows by: text, hex when the schema declares Bytes. */
function entityId(id: Value): string {
  return id.kind === ValueKind.BYTES ? id.toBytes().toHexString() : id.toString();
}

const entityTail = new Proxy(Object.create(null), {
  get(_target, prop, receiver) {
    if (typeof prop === "symbol" || PROTOTYPE_PASSTHROUGH.has(prop as string)) {
      return undefined;
    }
    if (prop === "save" && receiver instanceof Entity) {
      const entityType = (receiver as any)[ENTITY_TYPE];
      if (typeof entityType === "string") {
        return () => {
          const id = receiver.get("id");
          if (id === null) {
            throw new Error(`Cannot save ${entityType} entity without an ID`);
          }
          storeImpl.set(entityType, entityId(id), receiver);
        };
      }
    }
    const stored = receiver instanceof Entity ? receiver.get(prop as string) : null;
    if (stored !== null) {
      return valueToNative(stored);
    }
    // A derived field is a query the generated getter would have run, so it is
    // answered here for the same reason `save()` is: `changetype` erased the
    // prototype that carried it.
    if (receiver instanceof Entity) {
      const entityType = (receiver as any)[ENTITY_TYPE];
      const declared =
        typeof entityType === "string"
          ? currentScope().schema.entityFieldTypes[entityType]?.[prop as string]
          : undefined;
      if (declared?.derivedFrom) {
        const id = receiver.get("id");
        if (id === null) {
          throw new Error(
            `Cannot load ${entityType}.${String(prop)} on an entity without an ID`,
          );
        }
        const owner = entityId(id);
        return { load: () => storeImpl.loadRelated(entityType, owner, prop as string) };
      }
    }
    // graph-node's store returns every column; envio's returns what the mapping
    // wrote, so a field nothing has set is simply absent. It is still a field,
    // and reading it is a null check — ENS opens with one.
    const entityType = (receiver as any)?.[ENTITY_TYPE];
    if (typeof entityType === "string") {
      const declared = currentScope().schema.entityFields[entityType];
      if (declared?.includes(prop as string)) {
        return null;
      }
    }
    // Only an entity read is a schema field access. A plain TypedMap — what
    // JSONValue.toObject() hands back — has to keep ordinary JS semantics, or
    // every host probe for `toJSON` or `then` raises from unrelated code.
    if (!(receiver instanceof Entity)) {
      return undefined;
    }
    throw unknown(`the entity member ${String(prop)}`, "a mapping handler");
  },
  set(_target, prop, value, receiver) {
    // `entries` is TypedMap's own storage, and its class-field initializer is a
    // plain assignment — which walks the prototype chain and lands here before
    // the instance has the property. Routing it into `set()` would leave the
    // map with nowhere to store anything.
    if (typeof prop === "symbol" || prop === "entries" || !(receiver instanceof Entity)) {
      return Reflect.defineProperty(receiver as object, prop, {
        value,
        writable: true,
        enumerable: true,
        configurable: true,
      });
    }
    receiver.set(prop as string, nativeToValue(value));
    return true;
  },
});

Object.setPrototypeOf(TypedMap.prototype, entityTail);

// ---------------------------------------------------------------------------
// store
// ---------------------------------------------------------------------------

/**
 * What converting one entity type's rows needs from the schema, worked out the
 * first time it is needed: every load and every save converts a row, and the
 * schema doesn't change under a running indexer.
 */
type EntityLayout = {
  timestampFields: Set<string>;
  refFields: Set<string>;
  listFields: Set<string>;
  /** A stored column as the field it reads back into, and that field's kind. */
  columns: Map<string, { key: string; kind: string | undefined; timestamp: boolean }>;
};

const entityLayouts = new WeakMap<Scope["schema"], Map<string, EntityLayout>>();

function entityLayout(schema: Scope["schema"], entityType: string): EntityLayout {
  let layouts = entityLayouts.get(schema);
  if (!layouts) {
    layouts = new Map();
    entityLayouts.set(schema, layouts);
  }
  let layout = layouts.get(entityType);
  if (!layout) {
    layout = {
      timestampFields: new Set(schema.timestampFields[entityType] ?? []),
      refFields: new Set(schema.entityRefFields[entityType] ?? []),
      listFields: new Set(schema.entityListFields[entityType] ?? []),
      columns: new Map(),
    };
    layouts.set(entityType, layout);
  }
  return layout;
}

function columnOf(schema: Scope["schema"], entityType: string, layout: EntityLayout, column: string) {
  let known = layout.columns.get(column);
  if (!known) {
    const key =
      column.endsWith("_id") && layout.refFields.has(column.slice(0, -3)) ? column.slice(0, -3) : column;
    known = {
      key,
      kind: declaredKind(schema, (schema.entityFieldTypes[entityType] ?? {})[key]),
      timestamp: layout.timestampFields.has(key),
    };
    layout.columns.set(column, known);
  }
  return known;
}

/** graph-ts `Value`s -> the plain scalars envio stores. */
let warnedPointerBytes = false;

/**
 * An Array that AssemblyScript reads as a Uint8Array — `graph init`'s
 * `changetype<Bytes[]>(event.params.structs)` — is its backing buffer, the
 * two classes sharing the ArrayBufferView header: one little-endian four-byte
 * pointer per element. graph-node's allocator picked those addresses; these
 * are stand-ins, as many bytes, and the run says so once.
 */
function pointerBytes(elements: unknown[]): Bytes {
  if (!warnedPointerBytes) {
    warnedPointerBytes = true;
    warn(
      "Envio Subgraph: a mapping stores an array (an ethereum.Tuple, often) as Bytes, as graph init's " +
        "`changetype<Bytes[]>(event.params.<structs>)` does. graph-node stores the wasm memory addresses of " +
        "its elements there; envio stores as many bytes of stand-in addresses, so those values differ.",
    );
  }
  const bytes = new Bytes(elements.length * 4);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  elements.forEach((element, index) => view.setUint32(index * 4, Number(operators.address(element)) >>> 0, true));
  return bytes;
}

function toRow(entityType: string, entity: Entity): Record<string, unknown> {
  const { schema } = currentScope();
  // graph-ts holds a relation as the related entity's id under the field's own
  // name; envio's column for it is `<field>_id`.
  const { timestampFields, refFields, listFields } = entityLayout(schema, entityType);
  const row: Record<string, unknown> = {};
  for (const entry of entriesOf(entity)) {
    const column = refFields.has(entry.key) ? `${entry.key}_id` : entry.key;
    // An id is a string column whatever the subgraph declared it as, and so is
    // a relation, which carries one. Every other `Bytes` field is a bytes
    // column, which is what `bytes_type: uint8array` makes of it.
    const isId = entry.key === "id" || refFields.has(entry.key) || listFields.has(entry.key);
    row[column] =
      timestampFields.has(entry.key) && entry.value.kind !== ValueKind.NULL
        ? new Date(Number(entry.value.toTimestamp() / 1000n))
      : fromValue(entry.value, isId);
  }
  return row;
}

function fromValue(value: Value, isId = false): unknown {
  switch (value.kind) {
    case ValueKind.NULL:
      return null;
    case ValueKind.BYTES:
      return isId ? value.toBytes().toHexString() : Uint8Array.from(value.toBytes());
    case ValueKind.BIGINT:
      return value.toBigInt().valueOf();
    case ValueKind.INT8:
    case ValueKind.TIMESTAMP:
      return BigInt(value.data as any);
    case ValueKind.BIGDECIMAL:
      return value.toBigDecimal().value;
    case ValueKind.ARRAY:
      return value.toArray().map((item) => fromValue(item, isId));
    case ValueKind.STRING:
      return withoutNul(value.data);
    default:
      return value.data;
  }
}

/**
 * graph-node drops every NUL from a string that crosses from the mapping to the
 * host ("Strip null characters since they are not accepted by Postgres",
 * `FromAscObj<AscString> for String`), so a bytes32 symbol padded with NULs and
 * decoded as a string is stored without them. Postgres refuses 0x00 in text.
 */
function withoutNul<T>(text: T): T {
  // A String field a mapping filled with null (graph-ts' `logType`) is not text.
  return typeof text === "string" && text.includes("\u0000") ? (text.replaceAll("\u0000", "") as T) : text;
}

/** envio rows -> graph-ts `Value`s. */
function toEntity(entityType: string, row: Record<string, unknown> | undefined | null): Entity | null {
  if (row === undefined || row === null) {
    return null;
  }
  const { schema } = currentScope();
  const layout = entityLayout(schema, entityType);
  const entity = new Entity();
  Object.defineProperty(entity, ENTITY_TYPE, { value: entityType });
  for (const column of Object.keys(row)) {
    const value = row[column];
    const { key, kind, timestamp } = columnOf(schema, entityType, layout, column);
    entity.set(
      key,
      timestamp && value !== null && value !== undefined
        ? Value.fromTimestamp(BigInt((value as Date).getTime()) * 1000n)
        : toValue(value, kind),
    );
  }
  return entity;
}

/**
 * What a mapping expects a field to read back as. A relation carries the id of
 * the entity it points at, so its type is that entity's own `id` type — which is
 * how `Token.load(pool.token0)` gets `Bytes` rather than a string.
 */
function declaredKind(
  schema: { entityFieldTypes: Record<string, Record<string, { kind: string; target?: string; list?: boolean }>> },
  field: { kind: string; target?: string; list?: boolean } | undefined,
): string | undefined {
  if (!field) return undefined;
  // For a list, this is the element's kind — a list of entity ids carries the
  // ids themselves, so each one is the target entity's id type.
  if (field.kind !== "Entity") return field.kind;
  const target = field.target ? schema.entityFieldTypes[field.target] : undefined;
  return target?.id?.kind;
}

function toValue(value: unknown, kind?: string): Value {
  if (value === null || value === undefined) return Value.fromNull();
  if (Array.isArray(value)) return Value.fromArray(value.map((item) => toValue(item, kind)));
  switch (kind) {
    case "Bytes":
      // A bytes column reads back as the bytes themselves; an id column
      // declared `Bytes` is stored as text, and reads back hex.
      if (value instanceof Uint8Array) return Value.fromBytes(Bytes.fromUint8Array(value));
      return typeof value === "string" ? Value.fromBytes(Bytes.fromHexString(value)) : Value.fromNull();
    case "BigInt":
    case "Int8":
      return Value.fromBigInt(typeof value === "bigint" ? new BigInt_(value) : BigInt_.fromString(String(value)));
    case "BigDecimal":
      return Value.fromBigDecimal(
        value instanceof BigNumber ? new BigDecimal(value) : BigDecimal.fromString(String(value)),
      );
    case "Int":
      return Value.fromI32(Number(value));
    case "Boolean":
      return Value.fromBoolean(Boolean(value));
    default:
      break;
  }
  if (typeof value === "string") return Value.fromString(value);
  if (typeof value === "boolean") return Value.fromBoolean(value);
  if (typeof value === "number") return Value.fromI32(value);
  if (typeof value === "bigint") return Value.fromBigInt(new BigInt_(value));
  if (Array.isArray(value)) return Value.fromArray(value.map((item) => toValue(item)));
  if (value instanceof BigNumber) return Value.fromBigDecimal(new BigDecimal(value));
  return Value.fromString(String(value));
}

function entityContext(entityType: string) {
  const { context, schema } = currentScope();
  const accessor = schema.entityAccessors[entityType];
  const table = accessor === undefined ? undefined : context[accessor];
  if (!table) {
    throw unknown(`the entity ${entityType}`, "a mapping handler");
  }
  return table;
}

/**
 * What the register passes have written, at the position of the event that
 * wrote it. Nothing is in envio's store at fetch time, so this is the register
 * pass's only notion of state: a handler that loads an entity an earlier
 * creating handler saved — Aave's `handleReserveInitialized` before
 * `ATokenContract.create()`, Venus's `getOrCreateMarket` — sees it, as it
 * would on graph-node, instead of null. A read only sees writes from strictly
 * earlier events on its chain; anything evicted past the cap, or written by a
 * handler that creates nothing (and so gets no register pass), reads null as
 * before.
 */
const registerStore = new Map<string, { position: number; row: Record<string, unknown> | null }[]>();
/** Least recently used entities go first: a factory's own entity stays hot. */
const REGISTER_STORE_LIMIT = 50_000;
const REGISTER_STORE_VERSIONS = 4;
/**
 * Writes of one block beyond these are dropped oldest first. The passes of a
 * block's creation rounds read out of log order — a round-1 event logged before
 * the deployer reads the deployer's write, below a few later writes of its own
 * round — so the versions a block adds cannot evict the ones below it.
 */
const REGISTER_STORE_BLOCK_VERSIONS = 64;

function registerStoreKey(chainId: number, entityType: string, id: string): string {
  return `${chainId}\u0000${entityType}\u0000${id}`;
}

let registerMissHook: ((scope: Scope, key: string) => void) | null = null;

/** Called on a register-store miss; may suspend the pass to wait on another. */
export function installRegisterMissHook(hook: typeof registerMissHook) {
  registerMissHook = hook;
}

function registerRead(scope: Scope, entityType: string, id: string, sameBlock: boolean, wait = true) {
  const key = registerStoreKey(scope.dataSource.chainId, entityType, id);
  if (scope.writes?.has(key)) return toEntity(entityType, scope.writes.get(key));
  const position = scope.position ?? 0;
  const versions = registerStore.get(key) ?? [];
  if (versions.length > 0) {
    registerStore.delete(key);
    registerStore.set(key, versions);
  }
  for (let index = versions.length - 1; index >= 0; index--) {
    const version = versions[index];
    if (version.position >= position) continue;
    if (sameBlock && Math.floor(version.position / POSITION_BLOCK) !== Math.floor(position / POSITION_BLOCK)) {
      return null;
    }
    return toEntity(entityType, version.row);
  }
  if (wait) registerMissHook?.(scope, key);
  return null;
}

/**
 * An event's place in its chain: block, then the round graph-node runs it in
 * (the block's own triggers, then those of the data sources they created, and
 * so on), then log index.
 */
export const ROUND_SPAN = 1_000_000;
export const POSITION_BLOCK = 16 * ROUND_SPAN;

/**
 * Adds one write to an entity's versions, in position order. The newest few
 * versions of earlier blocks stay, and a bounded run of the newest block's own.
 */
export function addRegisterVersion(
  versions: { position: number; row: Record<string, unknown> | null }[],
  version: { position: number; row: Record<string, unknown> | null },
): void {
  const at = versions.findIndex((other) => other.position >= version.position);
  if (at === -1) versions.push(version);
  else if (versions[at].position === version.position) versions[at] = version;
  else versions.splice(at, 0, version);
  const newest = Math.floor(versions[versions.length - 1].position / POSITION_BLOCK);
  const blockStart = versions.findIndex((other) => Math.floor(other.position / POSITION_BLOCK) === newest);
  const dropOlder = blockStart - REGISTER_STORE_VERSIONS;
  if (dropOlder > 0) versions.splice(0, dropOlder);
  const keptOlder = Math.min(blockStart, REGISTER_STORE_VERSIONS);
  const dropBlock = versions.length - keptOlder - REGISTER_STORE_BLOCK_VERSIONS;
  if (dropBlock > 0) versions.splice(keptOlder, dropBlock);
}

/** Keeps a completed register round's writes for the passes after it. */
export function commitRegisterWrites(scope: Scope): void {
  const writes = scope.writes;
  scope.writes = undefined;
  if (!writes || writes.size === 0) return;
  const position = scope.position ?? 0;
  for (const [key, row] of writes) {
    let versions = registerStore.get(key);
    if (versions) {
      registerStore.delete(key);
    } else {
      versions = [];
      if (registerStore.size >= REGISTER_STORE_LIMIT) {
        registerStore.delete(registerStore.keys().next().value!);
      }
    }
    registerStore.set(key, versions);
    addRegisterVersion(versions, { position, row });
  }
}

/** Between test indexers, whose chains restart at block zero. */
export function resetRegisterStore(): void {
  registerStore.clear();
}

/**
 * A field a new entity never set is null in graph-node's store; envio's write
 * needs it spelled out — a list column refuses a missing value.
 */
function withUnsetAsNull(scope: Scope, entityType: string, row: Record<string, unknown>) {
  const refFields = new Set(scope.schema.entityRefFields[entityType] ?? []);
  for (const [field, declared] of Object.entries(scope.schema.entityFieldTypes[entityType] ?? {})) {
    if (declared.derivedFrom) continue;
    const column = refFields.has(field) ? `${field}_id` : field;
    if (!(column in row)) row[column] = null;
  }
  return row;
}

function registerWrite(scope: Scope, entityType: string, id: string, row: Record<string, unknown> | null) {
  scope.writes ??= new Map();
  scope.writes.set(registerStoreKey(scope.dataSource.chainId, entityType, id), row);
}

/**
 * A file data source reaches the types its manifest entry lists, as graph-node
 * enforces, and only what it wrote itself. Returns whether the entity is one it
 * wrote; `false` for a scope that isn't a file data source's.
 */
function fileAccess(scope: Scope, entityType: string, id: string): boolean | null {
  const file = scope.file;
  if (!file) return null;
  if (!file.entities.has(entityType)) {
    throw new Error(
      `entity type \`${entityType}\` is not on the 'entities' list for data source ` +
        `\`${scope.dataSource.name}\`. Hint: Add \`${entityType}\` to the 'entities' list, which ` +
        `currently is: \`${[...file.entities].join(", ")}\`.`,
    );
  }
  return file.written.has(`${entityType}\u0000${id}`);
}

const storeImpl = {
  get(entityType: string, id: string): Entity | null {
    id = withoutNul(id);
    const scope = currentScope();
    if (fileAccess(scope, entityType, id) === false) return null;
    if (scope.mode === "register") return registerRead(scope, entityType, id, false);
    return toEntity(entityType, entityContext(entityType).getSync(id));
  },
  get_in_block(entityType: string, id: string): Entity | null {
    id = withoutNul(id);
    const scope = currentScope();
    if (fileAccess(scope, entityType, id) === false) return null;
    if (scope.mode === "register") return registerRead(scope, entityType, id, true);
    return toEntity(entityType, entityContext(entityType).getInBlockSync(id));
  },
  set(entityType: string, id: string, data: Entity): void {
    id = withoutNul(id);
    const scope = currentScope();
    const own = fileAccess(scope, entityType, id);
    if (scope.file) scope.file.written.add(`${entityType}\u0000${id}`);
    const row = toRow(entityType, data);
    row.id = id;
    // graph-node merges a save onto the stored entity (EntityCache::set is an
    // Update, merged by merge_remove_null_fields): a field this instance
    // doesn't set keeps its stored value, an explicit null clears it. ENS's
    // handleAddrChanged saves a fresh `new Resolver(id)` and relies on it.
    if (scope.mode === "register") {
      const stored = registerRead(scope, entityType, id, false, false);
      return registerWrite(scope, entityType, id, stored ? { ...toRow(entityType, stored), ...row } : row);
    }
    const table = entityContext(entityType);
    if (scope.schema.timeseriesEntities.includes(entityType)) {
      // graph-node overrides whatever id and timestamp the mapping set.
      const sequence = scope.timeseriesSequence ?? 0;
      scope.timeseriesSequence = sequence + 1;
      row.id = timeseriesId(scope.blockNumber, scope.event?.logIndex ?? -1, sequence);
      row.timestamp = new Date(Number(scope.blockSeconds?.() ?? 0) * 1000);
      return table.set(withUnsetAsNull(scope, entityType, row));
    }
    // A file data source's first write of an id is a new entity of its own,
    // whatever a chain handler stored under the same id.
    const stored = own === false ? undefined : table.getSync(id);
    table.set(stored ? { ...stored, ...row } : withUnsetAsNull(scope, entityType, row));
  },
  remove(entityType: string, id: string): void {
    id = withoutNul(id);
    const scope = currentScope();
    if (fileAccess(scope, entityType, id) === false) return;
    if (scope.mode === "register") return registerWrite(scope, entityType, id, null);
    entityContext(entityType).deleteUnsafe(id);
  },
  /**
   * `graph codegen` names the entity the derived field is declared on and the
   * field's own name, so the lookup it stands for — the other entity's table,
   * filtered on the field that points back — is resolved from the schema.
   */
  loadRelated(entityType: string, id: string, field: string): Entity[] {
    const { mode, schema, file } = currentScope();
    if (mode === "register") return [];
    if (file && !file.entities.has(entityType)) fileAccess(currentScope(), entityType, id);
    const declared = schema.entityFieldTypes[entityType]?.[field];
    if (!declared?.target || !declared.derivedFrom) {
      throw unknown(`the derived field ${entityType}.${field}`, "a mapping handler");
    }
    const target = declared.target;
    // graph-node answers with every entity whose list holds the id; envio's
    // lookups only match a column equal to a value, so the list would read as
    // empty — refused rather than answered wrong.
    if (schema.entityListFields[target]?.includes(declared.derivedFrom)) {
      throw unsupported(
        `loading ${entityType}.${field}, derived from the list field ${target}.${declared.derivedFrom}`,
        "a mapping handler",
      );
    }
    const back = schema.entityRefFields[target]?.includes(declared.derivedFrom)
      ? `${declared.derivedFrom}_id`
      : declared.derivedFrom;
    const rows = entityContext(target).getWhereSync({ [back]: { _eq: id } });
    // A file data source sees the related entities it wrote, and no others.
    const visible = file
      ? rows.filter((row: any) => file.entities.has(target) && file.written.has(`${target}\u0000${row.id}`))
      : rows;
    return visible.map((row: any) => toEntity(target, row) as Entity);
  },
};

export const store = strictNamespace("store", storeImpl);

// ---------------------------------------------------------------------------
// ethereum
// ---------------------------------------------------------------------------

/**
 * An ABI value, tagged with its Solidity kind the way graph-ts tags it — a
 * mapping may switch on `kind`, and each accessor refuses a value of another
 * kind rather than coerce it.
 */
export class EthereumValue {
  constructor(
    public kind: EthereumValueKind,
    public data: any,
  ) {}

  static fromAddress(value: Address): EthereumValue {
    return new EthereumValue(EthereumValueKind.ADDRESS, value);
  }
  static fromBoolean(value: boolean): EthereumValue {
    return new EthereumValue(EthereumValueKind.BOOL, value);
  }
  static fromBytes(value: Bytes): EthereumValue {
    return new EthereumValue(EthereumValueKind.BYTES, value);
  }
  static fromFixedBytes(value: Bytes): EthereumValue {
    return new EthereumValue(EthereumValueKind.FIXED_BYTES, value);
  }
  static fromI32(value: number): EthereumValue {
    return new EthereumValue(EthereumValueKind.INT, BigInt_.fromI32(value));
  }
  static fromSignedBigInt(value: BigInt_): EthereumValue {
    return new EthereumValue(EthereumValueKind.INT, value);
  }
  static fromUnsignedBigInt(value: BigInt_): EthereumValue {
    return new EthereumValue(EthereumValueKind.UINT, value);
  }
  static fromString(value: string): EthereumValue {
    return new EthereumValue(EthereumValueKind.STRING, value);
  }
  static fromArray(values: EthereumValue[]): EthereumValue {
    return new EthereumValue(EthereumValueKind.ARRAY, values);
  }
  static fromFixedSizedArray(values: EthereumValue[]): EthereumValue {
    return new EthereumValue(EthereumValueKind.FIXED_ARRAY, values);
  }
  static fromTuple(values: EthereumValue[]): EthereumValue {
    return new EthereumValue(
      EthereumValueKind.TUPLE,
      values instanceof EthereumTuple ? values : EthereumTuple.from(values),
    );
  }
  static fromMatrix = arrayOf(EthereumValue.fromArray);
  static fromTupleArray = arrayOf(EthereumValue.fromTuple);
  static fromTupleMatrix = arrayOf(EthereumValue.fromTupleArray);
  static fromBooleanArray = arrayOf(EthereumValue.fromBoolean);
  static fromBytesArray = arrayOf(EthereumValue.fromBytes);
  static fromFixedBytesArray = arrayOf(EthereumValue.fromFixedBytes);
  static fromAddressArray = arrayOf(EthereumValue.fromAddress);
  static fromStringArray = arrayOf(EthereumValue.fromString);
  static fromI32Array = arrayOf(EthereumValue.fromI32);
  static fromSignedBigIntArray = arrayOf(EthereumValue.fromSignedBigInt);
  static fromUnsignedBigIntArray = arrayOf(EthereumValue.fromUnsignedBigInt);
  static fromBooleanMatrix = arrayOf(EthereumValue.fromBooleanArray);
  static fromBytesMatrix = arrayOf(EthereumValue.fromBytesArray);
  static fromFixedBytesMatrix = arrayOf(EthereumValue.fromFixedBytesArray);
  static fromAddressMatrix = arrayOf(EthereumValue.fromAddressArray);
  static fromStringMatrix = arrayOf(EthereumValue.fromStringArray);
  static fromI32Matrix = arrayOf(EthereumValue.fromI32Array);
  static fromSignedBigIntMatrix = arrayOf(EthereumValue.fromSignedBigIntArray);
  static fromUnsignedBigIntMatrix = arrayOf(EthereumValue.fromUnsignedBigIntArray);

  // graph-ts declares the comparison operators only to abort.
  lt(_: unknown): boolean {
    throw new Error("Less than operator isn't supported in Value");
  }
  gt(_: unknown): boolean {
    throw new Error("Greater than operator isn't supported in Value");
  }
  toAddress(): Address {
    return expectKind(this, "an address", EthereumValueKind.ADDRESS);
  }
  toBoolean(): boolean {
    return expectKind(this, "a boolean", EthereumValueKind.BOOL);
  }
  toBytes(): Bytes {
    return expectKind(this, "bytes", EthereumValueKind.FIXED_BYTES, EthereumValueKind.BYTES);
  }
  toI32(): number {
    return this.toBigInt().toI32();
  }
  toBigInt(): BigInt_ {
    return expectKind(this, "an int or uint", EthereumValueKind.INT, EthereumValueKind.UINT);
  }
  toString(): string {
    return expectKind(this, "a string", EthereumValueKind.STRING);
  }
  toArray(): EthereumValue[] {
    return expectKind(this, "an array", EthereumValueKind.ARRAY, EthereumValueKind.FIXED_ARRAY);
  }
  toTuple(): EthereumTuple {
    return expectKind(this, "a tuple", EthereumValueKind.TUPLE);
  }
  toMatrix(): EthereumValue[][] {
    return this.toArray().map((value) => value.toArray());
  }
  toTupleArray<T>(): T[] {
    return this.toArray().map((value) => value.toTuple() as unknown as T);
  }
  toTupleMatrix<T>(): T[][] {
    return this.toArray().map((value) => value.toTupleArray<T>());
  }
  toBooleanArray(): boolean[] {
    return this.toArray().map((value) => value.toBoolean());
  }
  toBytesArray(): Bytes[] {
    return this.toArray().map((value) => value.toBytes());
  }
  toAddressArray(): Address[] {
    return this.toArray().map((value) => value.toAddress());
  }
  toStringArray(): string[] {
    return this.toArray().map((value) => value.toString());
  }
  toI32Array(): number[] {
    return this.toArray().map((value) => value.toI32());
  }
  toBigIntArray(): BigInt_[] {
    return this.toArray().map((value) => value.toBigInt());
  }
  toBooleanMatrix(): boolean[][] {
    return this.toArray().map((value) => value.toBooleanArray());
  }
  toBytesMatrix(): Bytes[][] {
    return this.toArray().map((value) => value.toBytesArray());
  }
  toAddressMatrix(): Address[][] {
    return this.toArray().map((value) => value.toAddressArray());
  }
  toStringMatrix(): string[][] {
    return this.toArray().map((value) => value.toStringArray());
  }
  toI32Matrix(): number[][] {
    return this.toArray().map((value) => value.toI32Array());
  }
  toBigIntMatrix(): BigInt_[][] {
    return this.toArray().map((value) => value.toBigIntArray());
  }
}

function expectKind(value: EthereumValue, what: string, ...kinds: EthereumValueKind[]): any {
  if (!kinds.includes(value.kind)) throw new Error(`Ethereum value is not ${what}`);
  return value.data;
}

function arrayOf<T>(from: (value: T) => EthereumValue) {
  return (values: T[]): EthereumValue => EthereumValue.fromArray(values.map(from));
}

/** Generated struct classes extend this and read their fields by index. */
class EthereumTuple extends Array<EthereumValue> {}

class SmartContractCall {
  constructor(
    public contractName: string,
    public contractAddress: Address,
    public functionName: string,
    public functionSignature: string,
    public functionParams: EthereumValue[],
  ) {}
}

export class CallResult<T> {
  // Generated bindings signal a revert with a bare `new ethereum.CallResult()`.
  constructor(
    public reverted: boolean = true,
    private _value: T | null = null,
  ) {}
  get value(): T {
    if (this.reverted) {
      throw new Error("accessed value of a reverted call, please check the `reverted` field");
    }
    return this._value as T;
  }
  static fromValue<T>(value: T): CallResult<T> {
    return new CallResult(false, value);
  }
  static fromNullable<T>(value: T | null): CallResult<T> {
    return new CallResult(value === null, value);
  }
}

class SmartContract {
  constructor(
    public _name: string,
    public _address: Address,
  ) {}

  call(name: string, functionSignature: string | EthereumValue[], params?: EthereumValue[]): EthereumValue[] {
    const [signature, values] = signatureAndParams(this, name, functionSignature, params);
    return callContract(this, signature, values, false) as EthereumValue[];
  }

  tryCall(
    name: string,
    functionSignature: string | EthereumValue[],
    params?: EthereumValue[],
  ): CallResult<EthereumValue[]> {
    const [signature, values] = signatureAndParams(this, name, functionSignature, params);
    return callContract(this, signature, values, true) as CallResult<EthereumValue[]>;
  }
}

/**
 * Bindings from graph-cli before 0.18 call by name alone,
 * `super.call("ownerOf", [params])`, and graph-node takes the first function of
 * that name in the ABI (chain/ethereum/src/runtime/runtime_adapter.rs,
 * `contract.function(name)` when the call has no signature). Only the runtime
 * has the manifest's ABIs, so it installs the lookup.
 */
let legacySignatureHook: ((abiName: string, functionName: string) => string) | null = null;

export function installLegacySignatureHook(hook: typeof legacySignatureHook) {
  legacySignatureHook = hook;
}

function signatureAndParams(
  contract: SmartContract,
  name: string,
  functionSignature: string | EthereumValue[],
  params: EthereumValue[] | undefined,
): [string, EthereumValue[]] {
  if (typeof functionSignature === "string") return [functionSignature, params ?? []];
  if (!legacySignatureHook) {
    throw unsupported("contract calls by function name without the manifest's ABIs", `${contract._name}.${name}`);
  }
  return [legacySignatureHook(contract._name, name), functionSignature];
}

/**
 * Contract calls go through the shim's call hook, installed by the runtime so
 * this module stays free of envio imports. A transport failure is not a revert:
 * the call effect asks again until it answers, so a flaky RPC never fabricates
 * `{reverted: true}` data.
 */
let callHook:
  | ((call: SmartContractCall) => { reverted: boolean; value: unknown[] | null })
  | null = null;

export function installCallHook(hook: typeof callHook) {
  callHook = hook;
}

function callContract(
  contract: SmartContract,
  functionSignature: string,
  params: EthereumValue[],
  isTry: boolean,
) {
  if (!callHook) {
    throw unsupported(
      "contract calls without a configured RPC endpoint",
      `${contract._name}.${functionSignature}`,
    );
  }
  const call = new SmartContractCall(
    contract._name,
    contract._address,
    parseSignature(functionSignature).name,
    functionSignature,
    params,
  );
  // A suspend thrown by the underlying effect must escape `try_` too: it isn't
  // a revert, it's "not resolved yet".
  const result = callHook(call);
  const values = () => {
    const outputs = outputConverters(functionSignature);
    return (result.value ?? []).map((raw, index) => outputs[index](raw));
  };
  if (isTry) {
    return result.reverted ? new CallResult(true, null) : CallResult.fromValue(values());
  }
  if (result.reverted) {
    throw new Error(`Call to ${contract._name}.${functionSignature} reverted`);
  }
  return values();
}

const outputConverters = memoised((signature) =>
  splitTypes(parseSignature(signature).outputs).map(ethereumConverter),
);

/** An `ethereum.Value` as the plain JS an ABI encoder takes. */
export function ethereumValueToJs(value: EthereumValue): unknown {
  switch (value.kind) {
    case EthereumValueKind.ADDRESS:
    case EthereumValueKind.BYTES:
    case EthereumValueKind.FIXED_BYTES:
      return (value.data as Bytes).toHexString();
    case EthereumValueKind.INT:
    case EthereumValueKind.UINT:
      return (value.data as BigInt_).valueOf();
    case EthereumValueKind.ARRAY:
    case EthereumValueKind.FIXED_ARRAY:
    case EthereumValueKind.TUPLE:
      return (value.data as EthereumValue[]).map(ethereumValueToJs);
    default:
      return value.data;
  }
}

/**
 * One ABI token's encoding, and whether it is dynamic (encoded after the heads
 * of the sequence holding it, which points at it) or inline in its head.
 */
type EncodedToken = { dynamic: boolean; bytes: Uint8Array };

const WORD = 32;
const wordOf = (value: bigint): Uint8Array => hexToBytes(toHex(value, { size: WORD }));
const padded = (bytes: Uint8Array, left: boolean): Uint8Array => {
  const out = new Uint8Array(Math.ceil(bytes.length / WORD) * WORD || (left ? WORD : 0));
  out.set(bytes, left ? out.length - bytes.length : 0);
  return out;
};
const joined = (parts: Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let at = 0;
  for (const part of parts) {
    out.set(part, at);
    at += part.length;
  }
  return out;
};

function integerWord(value: BigInt_, signed: boolean): Uint8Array {
  const n = value.valueOf() as bigint;
  const [min, max] = signed ? [-(2n ** 255n), 2n ** 255n - 1n] : [0n, 2n ** 256n - 1n];
  if (n < min || n > max) throw new Error(`ethereum.encode: ${n} doesn't fit an ${signed ? "int" : "uint"}256`);
  return wordOf(BigInt.asUintN(256, n));
}

/** Heads in order, then the tails of the dynamic tokens the heads point at. */
function encodedSequence(items: EthereumValue[]): Uint8Array {
  const tokens = items.map(encodedToken);
  let offset = tokens.reduce((total, token) => total + (token.dynamic ? WORD : token.bytes.length), 0);
  const heads: Uint8Array[] = [];
  const tails: Uint8Array[] = [];
  for (const token of tokens) {
    if (!token.dynamic) {
      heads.push(token.bytes);
      continue;
    }
    heads.push(wordOf(BigInt(offset)));
    tails.push(token.bytes);
    offset += token.bytes.length;
  }
  return joined([...heads, ...tails]);
}

/**
 * Each token encodes by its own kind, the way alloy's `DynSolValue` (and
 * ethabi's `Token` before it) does. An array of unlike values, which no
 * Solidity type spells, still encodes element by element: Reserve hashes a
 * timelock batch as such an array's encoding minus its offset and length.
 */
function encodedToken(value: EthereumValue): EncodedToken {
  switch (value.kind) {
    case EthereumValueKind.ADDRESS:
    case EthereumValueKind.BOOL:
    case EthereumValueKind.INT:
    case EthereumValueKind.UINT:
      return { dynamic: false, bytes: staticWord(value) };
    case EthereumValueKind.FIXED_BYTES: {
      const bytes = value.data as Bytes;
      if (bytes.length > WORD) throw new Error(`ethereum.encode: fixed bytes of ${bytes.length} bytes`);
      const word = new Uint8Array(WORD);
      word.set(bytes);
      return { dynamic: false, bytes: word };
    }
    case EthereumValueKind.STRING:
    case EthereumValueKind.BYTES: {
      const bytes =
        value.kind === EthereumValueKind.STRING ? new TextEncoder().encode(value.data as string) : (value.data as Bytes);
      return { dynamic: true, bytes: joined([wordOf(BigInt(bytes.length)), padded(bytes, false)]) };
    }
    case EthereumValueKind.ARRAY: {
      const items = value.data as EthereumValue[];
      return { dynamic: true, bytes: joined([wordOf(BigInt(items.length)), encodedSequence(items)]) };
    }
    case EthereumValueKind.FIXED_ARRAY:
    case EthereumValueKind.TUPLE: {
      const items = value.data as EthereumValue[];
      return { dynamic: items.some((item) => encodedToken(item).dynamic), bytes: encodedSequence(items) };
    }
    default:
      throw new Error(`ethereum.encode can't encode a value of kind ${value.kind}`);
  }
}

function staticWord(value: EthereumValue): Uint8Array {
  switch (value.kind) {
    case EthereumValueKind.ADDRESS:
      return padded(value.data as Bytes, true);
    case EthereumValueKind.BOOL:
      return wordOf(value.data ? 1n : 0n);
    case EthereumValueKind.INT:
      return integerWord(value.data as BigInt_, true);
    default:
      return integerWord(value.data as BigInt_, false);
  }
}

/**
 * A graph-ts chain object as the runtime fills it in: `shaped` sets each field
 * off the decoded payload, so the constructor a mapping would call is skipped.
 */
function blank<T>(Class: abstract new (...args: any[]) => T): T {
  return Reflect.construct(Class, []) as T;
}

class EthereumBlock {
  declare hash: Bytes;
  declare parentHash: Bytes;
  declare unclesHash: Bytes;
  declare author: Address;
  declare stateRoot: Bytes;
  declare transactionsRoot: Bytes;
  declare receiptsRoot: Bytes;
  declare number: BigInt_;
  declare gasUsed: BigInt_;
  declare gasLimit: BigInt_;
  declare timestamp: BigInt_;
  declare difficulty: BigInt_;
  declare totalDifficulty: BigInt_;
  declare size: BigInt_ | null;
  declare baseFeePerGas: BigInt_ | null;

  constructor(
    hash: Bytes,
    parentHash: Bytes,
    unclesHash: Bytes,
    author: Address,
    stateRoot: Bytes,
    transactionsRoot: Bytes,
    receiptsRoot: Bytes,
    number: BigInt_,
    gasUsed: BigInt_,
    gasLimit: BigInt_,
    timestamp: BigInt_,
    difficulty: BigInt_,
    totalDifficulty: BigInt_,
    size: BigInt_ | null,
    baseFeePerGas: BigInt_ | null,
  ) {
    if (arguments.length === 0) return;
    Object.assign(this, {
      hash,
      parentHash,
      unclesHash,
      author,
      stateRoot,
      transactionsRoot,
      receiptsRoot,
      number,
      gasUsed,
      gasLimit,
      timestamp,
      difficulty,
      totalDifficulty,
      size,
      baseFeePerGas,
    });
  }
}

class EthereumTransaction {
  declare hash: Bytes;
  declare index: BigInt_;
  declare from: Address;
  declare to: Address | null;
  declare value: BigInt_;
  declare gasLimit: BigInt_;
  /**
   * graph-ts before 0.22's name for the slot graph-node fills with the gas
   * limit (`gas_limit` in every `AscEthereumTransaction_0_0_*`).
   */
  declare gasUsed: BigInt_;
  declare gasPrice: BigInt_;
  declare input: Bytes;
  declare nonce: BigInt_;

  constructor(
    hash: Bytes,
    index: BigInt_,
    from: Address,
    to: Address | null,
    value: BigInt_,
    gasLimit: BigInt_,
    gasPrice: BigInt_,
    input: Bytes,
    nonce: BigInt_,
  ) {
    if (arguments.length === 0) return;
    Object.assign(this, { hash, index, from, to, value, gasLimit, gasPrice, input, nonce });
  }
}

const NOT_DECODED = Symbol("envio.subgraph.notDecoded");

class EthereumEventParam {
  name: string;
  private _value: EthereumValue | typeof NOT_DECODED;
  private _raw: unknown = undefined;
  private _type = "";

  constructor(name: string, value: EthereumValue) {
    this.name = name;
    this._value = value;
  }

  /**
   * One of the runtime's own events' parameters, converted the first time it
   * is read: a handler reads a few of them, and graph codegen's getters reach
   * each one through the whole `parameters` array.
   */
  static decoded(name: string, type: string, raw: unknown): EthereumEventParam {
    const param = new EthereumEventParam(name, undefined as unknown as EthereumValue);
    param._value = NOT_DECODED;
    param._type = type;
    param._raw = raw;
    return param;
  }

  get value(): EthereumValue {
    if (this._value === NOT_DECODED) {
      this._value = ethereumConverter(this._type)(this._raw);
      this._raw = undefined;
    }
    return this._value;
  }
  set value(value: EthereumValue) {
    this._value = value;
    this._raw = undefined;
  }
}

/**
 * Only reachable through `event.receipt.logs`: envio's receipt selection
 * carries the scalars, so the log list is read when the mapping asks.
 */
class EthereumLog {
  constructor(
    public address: Address,
    public topics: Bytes[],
    public data: Bytes,
    public blockHash: Bytes,
    public blockNumber: Bytes,
    public transactionHash: Bytes,
    public transactionIndex: BigInt_,
    public logIndex: BigInt_,
    public transactionLogIndex: BigInt_,
    public logType: string,
    public removed: { inner: boolean } | null,
  ) {}
}

/** A transaction's logs as `receipts.ts` read them, in graph-ts' shape. */
function receiptLogsOf(json: string, blockHash: Bytes, blockNumber: number): EthereumLog[] {
  const raw = JSON.parse(json) as {
    address: string;
    topics: string[];
    data: string;
    logIndex: number;
    transactionIndex: number;
    transactionHash: string;
  }[];
  return raw.map(
    (log) =>
      new EthereumLog(
        Address.fromString(log.address),
        log.topics.map((topic) => Bytes.fromHexString(topic)),
        Bytes.fromHexString(log.data),
        blockHash,
        // graph-ts types it `Bytes`; graph-node fills it with the number's
        // signed little-endian bytes.
        Bytes.fromHexString("0x" + bigintToLittleEndianHex(BigInt(blockNumber))),
        Bytes.fromHexString(log.transactionHash),
        BigInt_.fromI32(log.transactionIndex),
        BigInt_.fromI32(log.logIndex),
        // Where no client sets it, graph-node falls back to the log index.
        BigInt_.fromI32(log.logIndex),
        null as unknown as string,
        new Wrapped(false),
      ),
  );
}

function bigintToLittleEndianHex(value: bigint): string {
  const bytes: string[] = [];
  let rest = value;
  do {
    bytes.push((Number(rest & 0xffn)).toString(16).padStart(2, "0"));
    rest >>= 8n;
  } while (rest > 0n);
  // Signed: a set top bit would read as negative, so a zero byte follows.
  if (parseInt(bytes[bytes.length - 1], 16) & 0x80) bytes.push("00");
  return bytes.join("");
}

class EthereumTransactionReceipt {
  declare transactionHash: Bytes;
  declare transactionIndex: BigInt_;
  declare blockHash: Bytes;
  declare blockNumber: BigInt_;
  declare cumulativeGasUsed: BigInt_;
  declare gasUsed: BigInt_;
  declare contractAddress: Address;
  declare logs: EthereumLog[];
  declare status: BigInt_;
  declare root: Bytes;
  declare logsBloom: Bytes;

  constructor(
    transactionHash: Bytes,
    transactionIndex: BigInt_,
    blockHash: Bytes,
    blockNumber: BigInt_,
    cumulativeGasUsed: BigInt_,
    gasUsed: BigInt_,
    contractAddress: Address,
    logs: EthereumLog[],
    status: BigInt_,
    root: Bytes,
    logsBloom: Bytes,
  ) {
    if (arguments.length === 0) return;
    Object.assign(this, {
      transactionHash,
      transactionIndex,
      blockHash,
      blockNumber,
      cumulativeGasUsed,
      gasUsed,
      contractAddress,
      logs,
      status,
      root,
      logsBloom,
    });
  }
}

/** What every call to one function shares. */
export type CallKind = {
  /** `data source "X" → "function(...)"`, for what a refusal names. */
  location: string;
  inputs: { name: string; type: string }[];
  outputs: { name: string; type: string }[];
};

const FROM_ENVIO_CALL = Symbol("envio.subgraph.call");

/** What a mapping-built call is, for anything that names where it came from. */
const BUILT_CALL: CallKind = { location: "an ethereum.Call the mapping built", inputs: [], outputs: [] };

/**
 * graph-ts' `ethereum.Call`, over one call item. A handler typed with a
 * generated call class receives an instance of that class — it extends this
 * one — so graph codegen's `inputs` and `outputs` getters read `inputValues` and
 * `outputValues` as written. Deferred like an event: a mapping that reads one
 * input shouldn't pay to convert the block, the transaction and every value.
 */
class EthereumCall {
  private _raw: any = null;
  private _kind: CallKind = BUILT_CALL;
  private _to: Address | undefined;
  private _from: Address | undefined;
  private _block: EthereumBlock | undefined;
  private _transaction: EthereumTransaction | undefined;
  private _inputValues: EthereumEventParam[] | undefined;
  private _outputValues: EthereumEventParam[] | undefined;

  constructor(
    to: Address,
    from: Address,
    block: EthereumBlock,
    transaction: EthereumTransaction,
    inputValues: EthereumEventParam[],
    outputValues: EthereumEventParam[],
  ) {
    if ((to as unknown) === FROM_ENVIO_CALL) {
      this._raw = from;
      this._kind = block as unknown as CallKind;
      return;
    }
    this._to = to;
    this._from = from;
    this._block = block;
    this._transaction = transaction;
    this._inputValues = inputValues ?? [];
    this._outputValues = outputValues ?? [];
  }

  /** The called contract. */
  get to(): Address {
    return (this._to ??= Address.fromString(this._raw.srcAddress));
  }
  set to(value: Address) {
    this._to = value;
  }
  /** The immediate caller, which is not the transaction's sender for an internal call. */
  get from(): Address {
    return (this._from ??= Address.fromString(this._raw.params.callFrom));
  }
  set from(value: Address) {
    this._from = value;
  }
  get block(): EthereumBlock {
    return (this._block ??= shaped(blank(EthereumBlock), BLOCK_SHAPE, this._raw.block));
  }
  set block(value: EthereumBlock) {
    this._block = value;
  }
  get transaction(): EthereumTransaction {
    return (this._transaction ??= shaped(blank(EthereumTransaction), TRANSACTION_SHAPE, this._raw.transaction));
  }
  set transaction(value: EthereumTransaction) {
    this._transaction = value;
  }
  get inputValues(): EthereumEventParam[] {
    return (this._inputValues ??= decodeCallValues(this._kind.inputs, this._raw.params.callInput, true));
  }
  set inputValues(value: EthereumEventParam[]) {
    this._inputValues = value;
  }
  get outputValues(): EthereumEventParam[] {
    return (this._outputValues ??= decodeCallValues(this._kind.outputs, this._raw.params.callOutput, false));
  }
  set outputValues(value: EthereumEventParam[]) {
    this._outputValues = value;
  }
}

/** The call the runtime hands a handler, as the generated class the handler declares. */
export function makeCall(raw: unknown, kind: CallKind, CallClass: Function): EthereumCall {
  return Reflect.construct(EthereumCall, [FROM_ENVIO_CALL, raw, kind], CallClass) as EthereumCall;
}

/**
 * A call's inputs or outputs, which the ABI types and the bytes carry. An input
 * is the calldata past its 4-byte selector; an output is the return data.
 */
function decodeCallValues(
  params: { name: string; type: string }[],
  data: string,
  isInput: boolean,
): EthereumEventParam[] {
  if (params.length === 0) return [];
  const bytes = (isInput ? `0x${data.slice(10)}` : data) as `0x${string}`;
  const decoded = decodeAbiParameters(parseAbiParameters(params.map((param) => param.type).join(",")), bytes);
  return params.map(
    (param, index) => new EthereumEventParam(param.name, ethereumConverter(param.type)(decoded[index])),
  );
}

/**
 * Whether a call's input decodes against its function — graph-node skips a call
 * whose calldata doesn't (it warns), and fails on an output that doesn't.
 */
export function callInputDecodes(kind: CallKind, input: string): boolean {
  try {
    decodeCallValues(kind.inputs, input, true);
    return true;
  } catch {
    return false;
  }
}

/** One of an event's parameters, as the translator read it off the ABI. */
export type EventInput = { name: string; key: string; type: string; indexed?: boolean };

/** What every occurrence of one kind of event shares. */
export type EventKind = {
  /** `data source "X" → "Event"`, for what a refusal names. */
  location: string;
  inputs: EventInput[];
  hasReceipt: boolean;
};

/**
 * graph-ts' block, transaction and receipt fields, each paired with the name
 * envio decodes it under and the type it arrives as. The names diverge both
 * ways — graph-ts' `author` is envio's `miner`, a transaction's `gasLimit` is
 * envio's `gas` — so a mapping reading the graph-ts name would get `undefined`.
 */
type Shape<T> = { [K in keyof T]-?: [rawName: string, kind: "bytes" | "address" | "bigint"] };

const BLOCK_SHAPE: Shape<EthereumBlock> = {
  hash: ["hash", "bytes"],
  parentHash: ["parentHash", "bytes"],
  unclesHash: ["sha3Uncles", "bytes"],
  author: ["miner", "address"],
  stateRoot: ["stateRoot", "bytes"],
  transactionsRoot: ["transactionsRoot", "bytes"],
  receiptsRoot: ["receiptsRoot", "bytes"],
  number: ["number", "bigint"],
  gasUsed: ["gasUsed", "bigint"],
  gasLimit: ["gasLimit", "bigint"],
  timestamp: ["timestamp", "bigint"],
  difficulty: ["difficulty", "bigint"],
  totalDifficulty: ["totalDifficulty", "bigint"],
  size: ["size", "bigint"],
  baseFeePerGas: ["baseFeePerGas", "bigint"],
};

const TRANSACTION_SHAPE: Shape<EthereumTransaction> = {
  hash: ["hash", "bytes"],
  index: ["transactionIndex", "bigint"],
  from: ["from", "address"],
  to: ["to", "address"],
  value: ["value", "bigint"],
  gasLimit: ["gas", "bigint"],
  gasUsed: ["gas", "bigint"],
  gasPrice: ["gasPrice", "bigint"],
  input: ["input", "bytes"],
  nonce: ["nonce", "bigint"],
};

/**
 * envio carries the receipt scalars on the transaction, and the block ones on
 * the block; the log list it doesn't carry at all.
 */
const RECEIPT_SHAPE: Shape<Omit<EthereumTransactionReceipt, "blockHash" | "blockNumber" | "logs">> = {
  transactionHash: ["hash", "bytes"],
  transactionIndex: ["transactionIndex", "bigint"],
  cumulativeGasUsed: ["cumulativeGasUsed", "bigint"],
  gasUsed: ["gasUsed", "bigint"],
  contractAddress: ["contractAddress", "address"],
  status: ["status", "bigint"],
  root: ["root", "bytes"],
  logsBloom: ["logsBloom", "bytes"],
};

function shaped<T extends object>(
  into: T,
  shape: Partial<Shape<T>>,
  raw: Record<string, unknown> | undefined,
): T {
  for (const [graphName, [rawName, kind]] of Object.entries(shape) as [string, Shape<T>[keyof T]][]) {
    const value = raw?.[rawName];
    (into as Record<string, unknown>)[graphName] =
      value === null || value === undefined
        ? null
        : kind === "bytes"
          ? Bytes.fromHexString(value as string)
          : kind === "address"
            ? Address.fromString(value as string)
            : new BigInt_(typeof value === "bigint" ? value : BigInt(value as number));
  }
  return into;
}

type Converter<T> = (raw: unknown) => T;

/**
 * Converters are compiled once per ABI type string or signature: every event
 * parameter and call output goes through one on every handler run, and a
 * replayed handler runs again.
 */
function memoised<V>(compile: (key: string) => V): (key: string) => V {
  const compiled = new Map<string, V>();
  return (key) => {
    let value = compiled.get(key);
    if (value === undefined) {
      value = compile(key);
      compiled.set(key, value);
    }
    return value;
  };
}

const tupleComponents = (type: string) => splitTypes(type.slice(1, type.lastIndexOf(")")));

/**
 * envio's decoder hands a `bytesN` over as the whole 32-byte word it was
 * encoded in, topic or body; graph-node keeps its first N bytes
 * (runtime/wasm/src/to_from/external.rs).
 */
function fixedBytes(type: string): Converter<Bytes> {
  const end = 2 + 2 * Number(type.slice("bytes".length));
  return (raw) => Bytes.fromHexString((raw as string).slice(0, end));
}

/**
 * The ABI type an event parameter's value arrives as. An indexed `string`,
 * `bytes`, array or tuple is only its topic, the keccak hash, which graph-node
 * hands over as a 32-byte `FixedBytes` and graph codegen reads as `bytes32`.
 */
function arrivesAs(input: EventInput): string {
  const { type } = input;
  const hashed = type === "string" || type === "bytes" || type.startsWith("(") || type.endsWith("]");
  return input.indexed && hashed ? "bytes32" : type;
}

/**
 * A decoded ABI value as the `ethereum.Value` graph-node would hand the
 * mapping, typed by the ABI rather than by its JS shape: a `string` holding
 * `0x…` is still a string.
 */
const ethereumConverter: (type: string) => Converter<EthereumValue> = memoised((type) => {
  if (type.endsWith("]")) {
    const element = ethereumConverter(type.slice(0, type.lastIndexOf("[")));
    const wrap = /\[\d+\]$/.test(type) ? EthereumValue.fromFixedSizedArray : EthereumValue.fromArray;
    return (raw) => wrap((raw as unknown[]).map((value) => element(value)));
  }
  if (type.startsWith("(")) {
    const components = tupleComponents(type).map(ethereumConverter);
    return (raw) => {
      // envio's decoder keys a tuple by its components' names when the ABI
      // gives them, in ABI order; viem and unnamed ABIs give an array.
      const values = Array.isArray(raw) ? raw : Object.values(raw as object);
      return EthereumValue.fromTuple(components.map((component, index) => component(values[index])));
    };
  }
  if (type === "address") return (raw) => EthereumValue.fromAddress(Address.fromString(raw as string));
  if (type === "bool") return (raw) => EthereumValue.fromBoolean(raw as boolean);
  if (type === "string") return (raw) => EthereumValue.fromString(raw as string);
  if (type === "bytes") return (raw) => EthereumValue.fromBytes(Bytes.fromHexString(raw as string));
  if (type.startsWith("bytes")) {
    const bytes = fixedBytes(type);
    return (raw) => EthereumValue.fromFixedBytes(bytes(raw));
  }
  // viem decodes the narrow integer types to numbers.
  const fromInt = type.startsWith("uint") ? EthereumValue.fromUnsignedBigInt : EthereumValue.fromSignedBigInt;
  return (raw) => fromInt(new BigInt_(BigInt(raw as bigint | number | string)));
});

/** Anything that fits in 32 bits is an `i32` in a mapping; wider is a BigInt. */
const SMALL_INT = /^u?int(8|16|24|32)$/;

/** A decoded ABI value as the graph-ts type `graph codegen` would give it. */
const graphConverter: (type: string) => Converter<unknown> = memoised((type) => {
  const convert = graphValue(type);
  return (raw) => (raw === null || raw === undefined ? raw : convert(raw));
});

function graphValue(type: string): Converter<unknown> {
  if (type.endsWith("]")) {
    const element = graphConverter(type.slice(0, type.lastIndexOf("[")));
    return (raw) => (raw as unknown[]).map((value) => element(value));
  }
  if (type.startsWith("(")) {
    const tuple = ethereumConverter(type);
    return (raw) => tuple(raw).toTuple();
  }
  if (type === "address") return (raw) => Address.fromString(raw as string);
  if (type === "bool" || type === "string") return (raw) => raw;
  if (type === "bytes") return (raw) => Bytes.fromHexString(raw as string);
  if (type.startsWith("bytes")) return fixedBytes(type);
  if (SMALL_INT.test(type)) return (raw) => Number(raw);
  return (raw) => new BigInt_(raw as bigint);
}

/**
 * graph-ts' `ethereum.Event`, over one decoded envio event. A handler typed with
 * a generated event class receives an instance of that class — it extends this
 * one — so graph codegen's own `params` getters read `parameters` as written.
 *
 * Everything is deferred: a mapping that reads two parameters shouldn't pay to
 * convert the block, the transaction and every parameter — and envio runs each
 * handler twice over the same payload, so anything eager is paid twice.
 */
const FROM_ENVIO = Symbol("envio.subgraph.event");

/** What a mapping-built event is, for anything that names where it came from. */
const BUILT_EVENT: EventKind = { location: "an ethereum.Event the mapping built", inputs: [], hasReceipt: false };

/** The event the runtime hands a handler, as the class the handler declares. */
export function makeEvent(raw: unknown, kind: EventKind, EventClass: Function): EthereumEvent {
  return Reflect.construct(EthereumEvent, [FROM_ENVIO, raw, kind], EventClass) as EthereumEvent;
}

class EthereumEvent {
  private _raw: any = null;
  private _kind: EventKind = BUILT_EVENT;
  private _address: Address | undefined;
  private _logIndex: BigInt_ | undefined;
  private _transactionLogIndex: BigInt_ | undefined;
  private _logType: string | null = null;
  private _block: EthereumBlock | undefined;
  private _transaction: EthereumTransaction | undefined;
  private _receipt: EthereumTransactionReceipt | null | undefined;
  private _parameters: EthereumEventParam[] | undefined;
  private _params: Record<string, unknown> | undefined;

  /**
   * graph-ts' own, for a mapping that builds an event — Notional synthesizes
   * one in a block handler. The runtime goes through `makeEvent` instead.
   */
  constructor(
    address: Address,
    logIndex: BigInt_,
    transactionLogIndex: BigInt_,
    logType: string | null,
    block: EthereumBlock,
    transaction: EthereumTransaction,
    parameters: EthereumEventParam[],
    receipt: EthereumTransactionReceipt | null,
  ) {
    if ((address as unknown) === FROM_ENVIO) {
      this._raw = logIndex;
      this._kind = transactionLogIndex as unknown as EventKind;
      return;
    }
    this._address = address;
    this._logIndex = logIndex;
    this._transactionLogIndex = transactionLogIndex;
    this._logType = logType;
    this._block = block;
    this._transaction = transaction;
    this._parameters = parameters ?? [];
    this._receipt = receipt ?? null;
  }

  get address(): Address {
    return (this._address ??= Address.fromString(this._raw.srcAddress));
  }
  set address(value: Address) {
    this._address = value;
  }
  get logIndex(): BigInt_ {
    return (this._logIndex ??= BigInt_.fromI32(this._raw.logIndex));
  }
  set logIndex(value: BigInt_) {
    this._logIndex = value;
  }
  get block(): EthereumBlock {
    return (this._block ??= shaped(blank(EthereumBlock), BLOCK_SHAPE, this._raw.block));
  }
  set block(value: EthereumBlock) {
    this._block = value;
  }
  get transaction(): EthereumTransaction {
    return (this._transaction ??= shaped(blank(EthereumTransaction), TRANSACTION_SHAPE, this._raw.transaction));
  }
  set transaction(value: EthereumTransaction) {
    this._transaction = value;
  }
  get receipt(): EthereumTransactionReceipt | null {
    if (this._receipt !== undefined) return this._receipt;
    if (!this._kind.hasReceipt) return null;
    const receipt = shaped(blank(EthereumTransactionReceipt), RECEIPT_SHAPE, this._raw.transaction);
    receipt.blockHash = this.block.hash;
    receipt.blockNumber = this.block.number;
    // The transaction's other logs aren't part of envio's event: read from
    // HyperSync (or the RPC) when the mapping first asks.
    const blockHash = receipt.blockHash;
    const blockNumber = Number(this._raw.block.number);
    const transactionIndex = Number(this._raw.transaction?.transactionIndex ?? this._raw.transactionIndex);
    const transactionHash = this._raw.transaction?.hash ?? this._raw.transactionHash;
    let logs: EthereumLog[] | undefined;
    Object.defineProperty(receipt, "logs", {
      enumerable: true,
      configurable: true,
      get: () =>
        (logs ??= receiptLogsOf(
          hostsOrThrow().receiptLogs(JSON.stringify({ blockNumber, transactionIndex, transactionHash })),
          blockHash,
          blockNumber,
        )),
      set: (value: EthereumLog[]) => {
        logs = value;
      },
    });
    return (this._receipt = receipt);
  }
  set receipt(value: EthereumTransactionReceipt | null) {
    this._receipt = value;
  }
  // graph-node reads it off the log, where no Ethereum client sets it.
  get logType(): string | null {
    return this._logType;
  }
  set logType(value: string | null) {
    this._logType = value;
  }
  get parameters(): EthereumEventParam[] {
    return (this._parameters ??= this._kind.inputs.map(
      (input) =>
        EthereumEventParam.decoded(input.name, arrivesAs(input), this._raw.params?.[input.key]),
    ));
  }
  set parameters(value: EthereumEventParam[]) {
    this._parameters = value;
    this._params = undefined;
  }
  /**
   * By name, for a handler not typed with a generated class — a generated
   * class's own getter wins otherwise. Named as graph codegen names them, so
   * an unnamed parameter reads as `param{index}`.
   */
  get params(): Record<string, unknown> {
    if (this._params) return this._params;
    const params: Record<string, unknown> = {};
    if (this._raw === null) {
      for (const parameter of this.parameters) params[parameter.name] = parameter.value;
      return (this._params = params);
    }
    this._kind.inputs.forEach((input, index) => {
      params[input.name || `param${index}`] = graphConverter(arrivesAs(input))(this._raw.params?.[input.key]);
    });
    return (this._params = params);
  }
  // graph-node answers the log's index in its block here (trigger.rs,
  // `transaction_log_index`): Geth never set the per-transaction one, and
  // subgraphs read it only to tell logs apart.
  get transactionLogIndex(): BigInt_ {
    return (this._transactionLogIndex ??= this.logIndex);
  }
  set transactionLogIndex(value: BigInt_) {
    this._transactionLogIndex = value;
  }
}

const ethereumImpl = {
  Value: EthereumValue,
  ValueKind: EthereumValueKind,
  SmartContract,
  SmartContractCall,
  CallResult,
  Block: EthereumBlock,
  Transaction: EthereumTransaction,
  TransactionReceipt: EthereumTransactionReceipt,
  Log: EthereumLog,
  Event: EthereumEvent,
  EventParam: EthereumEventParam,
  Call: EthereumCall,
  Tuple: EthereumTuple,
  call(call: SmartContractCall): EthereumValue[] | null {
    const contract = new SmartContract(call.contractName, call.contractAddress);
    const result = callContract(contract, call.functionSignature, call.functionParams, true);
    return (result as CallResult<EthereumValue[]>).reverted
      ? null
      : (result as CallResult<EthereumValue[]>).value;
  },
  decode(types: string, data: Bytes): EthereumValue | null {
    try {
      const decoded = decodeAbiParameters(
        parseAbiParameters(types),
        data.toHexString() as `0x${string}`,
      );
      return ethereumConverter(types)(decoded[0]);
    } catch {
      return null;
    }
  },
  // graph-node's `DynSolValue::abi_encode` (`ethabi::encode(&[token])` before
  // alloy), which is Solidity's `abi.encode` of the one value. A token carries
  // no integer width and every integer takes a full word.
  encode(value: EthereumValue): Bytes | null {
    try {
      return new Bytes(encodedSequence([value]));
    } catch {
      return null;
    }
  },
  getBalance(address: Address): BigInt_ {
    return BigInt_.fromString(hostsOrThrow().getBalance(address.toHexString()));
  },
  hasCode(address: Address): Wrapped<boolean> {
    return new Wrapped(hostsOrThrow().hasCode(address.toHexString()));
  },
};

export const ethereum = strictNamespace("ethereum", ethereumImpl);

// graph-ts before 0.18 (apiVersion 0.0.3 and older) exported these at the top
// level, and the mappings and generated code of that age import them so.
export {
  EthereumValueKind,
  EthereumTuple,
  EthereumBlock,
  EthereumTransaction,
  EthereumCall,
  EthereumEvent,
  EthereumEventParam,
  SmartContract,
};

/**
 * `matchstick-as`' test helper, which also resolves to this module (a mapping
 * file that holds test fixtures imports it beside its handlers — Forta's do).
 * Same defaults as matchstick-as/assembly/defaults.
 */
export function newMockEvent(): EthereumEvent {
  const address = Address.fromString("0xA16081F360e3847006dB660bae1c6d1b2e17eC2A");
  const hash = Bytes.fromHexString("0xA16081F360e3847006dB660bae1c6d1b2e17eC2A");
  const one = BigInt_.fromI32(1);
  const ten = BigInt_.fromI32(10);
  const block = new EthereumBlock(hash, hash, hash, address, hash, hash, hash, one, ten, ten, one, one, one, one, null);
  const transaction = new EthereumTransaction(hash, one, address, address, one, one, one, hash, one);
  return new EthereumEvent(address, one, one, "mock_log_type", block, transaction, [], null);
}

// ---------------------------------------------------------------------------
// dataSource + templates
// ---------------------------------------------------------------------------

let registerHook: ((templateName: string, address: string) => void) | null = null;
let handlerCreateHook: ((templateName: string, address: string) => void) | null = null;

export function installRegisterHook(hook: typeof registerHook) {
  registerHook = hook;
}

/** Sees each create() a handler (not a register pass) makes. */
export function installHandlerCreateHook(hook: typeof handlerCreateHook) {
  handlerCreateHook = hook;
}

/** The manifest's file templates: `create` queues these instead of registering an address. */
let fileTemplates = new Map<string, "ipfs" | "arweave">();

export function installFileTemplates(templates: Map<string, "ipfs" | "arweave">) {
  fileTemplates = templates;
}

/** A context, as a string that two equal contexts share (graph-node dedupes on it). */
function contextKey(context: DataSourceContext | undefined): string {
  if (!context || context.entries.length === 0) return "";
  const entries = context.entries.map((entry) => [entry.key, entry.value.kind, String(entry.value.data)]);
  return JSON.stringify(entries.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0)));
}

/** Two creations of the same file with the same context are one data source. */
export function fileCreateId(create: { template: string; source: string; context?: unknown }): string {
  const key = contextKey(create.context as DataSourceContext | undefined);
  return key === "" ? `${create.template}:${create.source}` : `${create.template}:${create.source}:${key}`;
}

function createFile(name: string, params: string[], context?: DataSourceContext): void {
  const scope = currentScope();
  const source = params[0];
  if (!source) {
    throw new Error(`${name}.create() was called without a file parameter`);
  }
  // Only the handler pass runs a file's handler; the register pass exists to
  // collect contract addresses.
  if (scope.mode === "register") return;
  const create = { template: name, source, context };
  const key = fileCreateId(create);
  scope.fileCreates ??= new Map();
  if (!scope.fileCreates.has(key)) scope.fileCreates.set(key, create);
}

export class DataSourceTemplate {
  static create(name: string, params: string[]): void {
    if (fileTemplates.has(name)) return createFile(name, params);
    const { mode, registered } = currentScope();
    const address = params[0];
    if (!address) {
      throw new Error(`${name}.create() was called without an address parameter`);
    }
    const key = `${name}:${address.toLowerCase()}`;
    if (mode !== "register") return handlerCreateHook?.(name, address);
    // Replays rerun the mapping from the top, so registration is deduped
    // rather than repeated.
    if (registered.has(key)) return;
    registered.add(key);
    registerHook?.(name, address);
  }
  static createWithContext(name: string, params: string[], context: DataSourceContext): void {
    if (fileTemplates.has(name)) return createFile(name, params, context);
    const { mode, dataSource } = currentScope();
    if (mode === "register" && entriesOf(context).length > 0 && params[0]) {
      rememberContext(dataSource.chainId, name, params[0], contextEntries(name, context));
    }
    DataSourceTemplate.create(name, params);
  }
}

/**
 * The context a template's data source was created with, which its handlers
 * read through `dataSource.context()`. The created address is all envio keeps
 * of a data source, so the context is kept here, by chain, template and
 * address — and in the project's `.envio` directory, so a restart that loads
 * the addresses from storage finds it again.
 */
type ContextEntries = Record<string, { type: string; data: string }>;
const dynamicContexts = new Map<string, ContextEntries>();
let contextsLoaded = false;

function contextFile(): string {
  return path.join(process.cwd(), ".envio", "subgraph-data-source-contexts.jsonl");
}

function dynamicContextKey(chainId: number, template: string, address: string): string {
  return `${chainId}:${template}:${address.toLowerCase()}`;
}

function loadContexts() {
  if (contextsLoaded) return;
  contextsLoaded = true;
  try {
    for (const line of readFileSync(contextFile(), "utf8").split("\n")) {
      if (!line) continue;
      const { key, entries } = JSON.parse(line);
      dynamicContexts.set(key, entries);
    }
  } catch {
    // none saved yet
  }
}

function rememberContext(chainId: number, template: string, address: string, entries: ContextEntries) {
  loadContexts();
  const key = dynamicContextKey(chainId, template, address);
  if (JSON.stringify(dynamicContexts.get(key)) === JSON.stringify(entries)) return;
  dynamicContexts.set(key, entries);
  try {
    mkdirSync(path.dirname(contextFile()), { recursive: true });
    appendFileSync(contextFile(), JSON.stringify({ key, entries }) + "\n");
  } catch {
    // in memory still serves this run
  }
}

/** The context `createWithContext` was given, for the handler pass of that data source. */
export function contextOf(chainId: number, template: string, address: string): ContextEntries | undefined {
  loadContexts();
  return dynamicContexts.get(dynamicContextKey(chainId, template, address));
}

/** The manifest's own typed entries (`contextValue`) run the other way. */
function contextEntries(template: string, context: DataSourceContext): ContextEntries {
  const out: ContextEntries = {};
  for (const entry of context.entries) {
    const value = entry.value;
    const key = entry.key;
    switch (value.kind) {
      case ValueKind.STRING:
        out[key] = { type: "String", data: value.toString() };
        break;
      case ValueKind.INT:
        out[key] = { type: "Int", data: String(value.toI32()) };
        break;
      case ValueKind.INT8:
        out[key] = { type: "Int8", data: String(value.data) };
        break;
      case ValueKind.BOOL:
        out[key] = { type: "Bool", data: String(value.toBoolean()) };
        break;
      case ValueKind.BIGINT:
        out[key] = { type: "BigInt", data: value.toBigInt().toString() };
        break;
      case ValueKind.BIGDECIMAL:
        out[key] = { type: "BigDecimal", data: value.toBigDecimal().toString() };
        break;
      case ValueKind.BYTES:
        out[key] = { type: "Bytes", data: value.toBytes().toHexString() };
        break;
      default:
        throw unsupported(
          `${template}.createWithContext() with a ${ValueKind[value.kind]} value on "${key}"`,
          "a mapping handler",
        );
    }
  }
  return out;
}

export class DataSourceContext extends Entity {}

/** A manifest `context` entry, typed the way graph-node types it. */
function contextValue(kind: string, data: string, key: string): Value {
  switch (kind) {
    case "Bool":
    case "Boolean":
      return Value.fromBoolean(data === "true");
    case "String":
      return Value.fromString(data);
    case "Int":
      return Value.fromI32(Number(data));
    case "Int8":
      return Value.fromI64(BigInt(data));
    case "BigInt":
      return Value.fromBigInt(BigInt_.fromString(data));
    case "BigDecimal":
      return Value.fromBigDecimal(BigDecimal.fromString(data));
    case "Bytes":
      return Value.fromBytes(Bytes.fromHexString(data));
    default:
      throw unknown(`the context value type ${kind} on "${key}"`, "a mapping handler");
  }
}

const dataSourceImpl = {
  address(): Address {
    const scope = currentScope();
    if (scope.file) {
      throw unsupported("dataSource.address() in a file data source, which has no contract", scope.dataSource.name);
    }
    return Address.fromString(scope.dataSource.address);
  },
  network(): string {
    return currentScope().dataSource.network;
  },
  context(): DataSourceContext {
    const context = new DataSourceContext();
    const created = currentScope().file?.context as DataSourceContext | undefined;
    if (created) {
      for (const entry of created.entries) context.set(entry.key, entry.value);
    }
    for (const [key, entry] of Object.entries(currentScope().dataSource.context ?? {})) {
      context.set(key, contextValue(entry.type, entry.data, key));
    }
    return context;
  },
  // The address a template was created with, which is the only string param
  // an EVM template ever carries.
  stringParam(): string {
    return currentScope().dataSource.address;
  },
  create: DataSourceTemplate.create,
  createWithContext: DataSourceTemplate.createWithContext,
};

export const dataSource = strictNamespace("dataSource", dataSourceImpl);

// ---------------------------------------------------------------------------
// log / crypto / json
// ---------------------------------------------------------------------------

function interpolate(message: string, args: string[]): string {
  let index = 0;
  return message.replace(/\{\}/g, () => args[index++] ?? "{}");
}

// The register pass runs the mapping against a store that reads null, so what
// it would log describes a world that doesn't exist; the handler pass logs it
// for real.
function userLog(level: "debug" | "info" | "warn" | "error", message: string, args: string[]) {
  const scope = currentScope();
  if (scope.mode === "register") return;
  scope.context.log?.[level](interpolate(message, args));
}

const logImpl = {
  Level: LogLevel,
  log(level: LogLevel, msg: string) {
    switch (level) {
      case LogLevel.CRITICAL:
        return logImpl.critical(msg);
      case LogLevel.ERROR:
        return logImpl.error(msg);
      case LogLevel.WARNING:
        return logImpl.warning(msg);
      case LogLevel.DEBUG:
        return logImpl.debug(msg);
      default:
        return logImpl.info(msg);
    }
  },
  debug(message: string, args: string[] = []) {
    userLog("debug", message, args);
  },
  info(message: string, args: string[] = []) {
    userLog("info", message, args);
  },
  warning(message: string, args: string[] = []) {
    userLog("warn", message, args);
  },
  error(message: string, args: string[] = []) {
    userLog("error", message, args);
  },
  // graph-node halts the subgraph on critical.
  critical(message: string, args: string[] = []): never {
    throw new Error(interpolate(message, args));
  },
};

export const log = strictNamespace("log", logImpl);

const cryptoImpl = {
  keccak256(input: ByteArray): ByteArray {
    return new ByteArray(subgraphKeccak256(input));
  },
};

export const crypto = strictNamespace("crypto", cryptoImpl);

const ethereumUtilsImpl = {
  getCreate2Address(from: Bytes, salt: Bytes, initCodeHash: Bytes): Bytes {
    const preimage =
      "0xff" +
      from.toHexString().slice(2) +
      salt.toHexString().slice(2) +
      initCodeHash.toHexString().slice(2);
    return Bytes.fromHexString(
      "0x" + viemKeccak256(hexToBytes(preimage as `0x${string}`)).slice(26),
    );
  },
};

export const EthereumUtils = strictNamespace("EthereumUtils", ethereumUtilsImpl);

export enum JSONValueKind {
  NULL = 0,
  BOOL = 1,
  NUMBER = 2,
  STRING = 3,
  ARRAY = 4,
  OBJECT = 5,
}

export class JSONValue {
  constructor(
    public kind: JSONValueKind,
    public data: any,
  ) {}
  toString(): string {
    return String(this.data);
  }
  toBool(): boolean {
    return Boolean(this.data);
  }
  isNull(): boolean {
    return this.kind === JSONValueKind.NULL;
  }
  toU64(): bigint {
    return this.toI64();
  }
  toI64(): bigint {
    return BigInt(this.data);
  }
  toF64(): number {
    return Number(this.data);
  }
  toBigInt(): BigInt_ {
    return BigInt_.fromString(String(this.data));
  }
  toArray(): JSONValue[] {
    return (this.data as unknown[]).map(fromJson);
  }
  toObject(): TypedMap<string, JSONValue> {
    const map = new TypedMap<string, JSONValue>();
    for (const [key, value] of Object.entries(this.data as object)) {
      map.set(key, fromJson(value));
    }
    return map;
  }
}

function fromJson(value: unknown): JSONValue {
  if (value === null) return new JSONValue(JSONValueKind.NULL, null);
  if (typeof value === "boolean") return new JSONValue(JSONValueKind.BOOL, value);
  if (typeof value === "number") return new JSONValue(JSONValueKind.NUMBER, value);
  if (typeof value === "string") return new JSONValue(JSONValueKind.STRING, value);
  if (Array.isArray(value)) return new JSONValue(JSONValueKind.ARRAY, value);
  return new JSONValue(JSONValueKind.OBJECT, value);
}

const jsonImpl = {
  fromBytes(bytes: Bytes): JSONValue {
    return fromJson(JSON.parse(new TextDecoder().decode(bytes)));
  },
  fromString(input: string): JSONValue {
    return fromJson(JSON.parse(input));
  },
  toI64(decimal: string): bigint {
    return BigInt(decimal);
  },
  toU64(decimal: string): bigint {
    return BigInt(decimal);
  },
  toF64(decimal: string): number {
    return Number(decimal);
  },
  toBigInt(decimal: string): BigInt_ {
    return BigInt_.fromString(decimal);
  },
  try_fromString(input: string): Result<JSONValue, boolean> {
    return tryParse(() => jsonImpl.fromString(input));
  },
  try_fromBytes(bytes: Bytes): Result<JSONValue, boolean> {
    return tryParse(() => jsonImpl.fromBytes(bytes));
  },
};

export const json = strictNamespace("json", jsonImpl);

/**
 * The host ops that reach outside the chain: each returns synchronously here
 * and suspends underneath, so the mapping keeps graph-ts' shape.
 */
export type Hosts = {
  ipfsCat: (hash: string) => string | null;
  ipfsMap: (hash: string, callback: string, userData: Value, flags: string[]) => void;
  arweaveData: (txId: string) => string | null;
  ensName: (hash: string) => string | null;
  getBalance: (address: string) => string;
  hasCode: (address: string) => boolean;
  blockTimestamp: (blockNumber: number) => string;
  /** The block's header as JSON, fields named as envio decodes them. */
  blockHeader: (blockNumber: number) => string;
  /** The logs of one transaction as JSON, given `{ blockNumber, transactionIndex, transactionHash }`. */
  receiptLogs: (transaction: string) => string;
};

let hosts: Hosts | null = null;

export function installHosts(installed: Hosts) {
  hosts = installed;
}

function hostsOrThrow(): Hosts {
  if (!hosts) {
    throw new Error("Envio Subgraph host ops were used before the runtime installed them.");
  }
  return hosts;
}

export function decodeBase64(encoded: string | null): Bytes | null {
  return encoded === null ? null : new Bytes(Buffer.from(encoded, "base64"));
}

const ipfsImpl = {
  cat(hash: string): Bytes | null {
    return decodeBase64(hostsOrThrow().ipfsCat(hash));
  },
  map(hash: string, callback: string, userData: Value, flags: string[]): void {
    hostsOrThrow().ipfsMap(hash, callback, userData, flags);
  },
  mapJSON(hash: string, callback: string, userData: Value): void {
    hostsOrThrow().ipfsMap(hash, callback, userData, ["json"]);
  },
};

export const ipfs = strictNamespace("ipfs", ipfsImpl);

const arweaveImpl = {
  transactionData(txId: string): Bytes | null {
    return decodeBase64(hostsOrThrow().arweaveData(txId));
  },
};

export const arweave = strictNamespace("arweave", arweaveImpl);

const ensImpl = {
  nameByHash(hash: string): string | null {
    return hostsOrThrow().ensName(hash);
  },
};

export const ens = strictNamespace("ens", ensImpl);

/** The whole block a call item carries, for a `filter: call` block handler. */
export function makeCallBlock(raw: unknown): EthereumBlock {
  return shaped(blank(EthereumBlock), BLOCK_SHAPE, raw as Record<string, unknown>);
}

/**
 * graph-ts hands a block handler an `ethereum.Block`. envio hands the handler
 * only the number, so the rest is fetched when the mapping first reads it:
 * `timestamp` on its own, narrowly; any other field as the whole header, once.
 * A header is only served from below the chain's reorg window (blocks.ts).
 */
export function makeBlockHandlerBlock(blockNumber: number, _location: string): EthereumBlock {
  const block = blank(EthereumBlock);
  block.number = BigInt_.fromI32(blockNumber);
  Object.defineProperty(block, "timestamp", {
    enumerable: true,
    configurable: true,
    // A header fetched for another field already carries it.
    get: () => (header ? header.timestamp : BigInt_.fromString(hostsOrThrow().blockTimestamp(blockNumber))),
  });
  let header: EthereumBlock | undefined;
  const fetched = () =>
    (header ??= shaped(blank(EthereumBlock), BLOCK_SHAPE, JSON.parse(hostsOrThrow().blockHeader(blockNumber))));
  for (const field of Object.keys(BLOCK_SHAPE) as (keyof EthereumBlock)[]) {
    if (field === "number" || field === "timestamp") continue;
    Object.defineProperty(block, field, {
      enumerable: true,
      configurable: true,
      get: () => fetched()[field],
    });
  }
  return block;
}

/**
 * AssemblyScript reinterprets the pointer and the layouts match, so nothing
 * happens at runtime — which leaves the value with whatever prototype it was
 * built with. A helper that returns `changetype<ByteArray>(new Uint8Array(n))`
 * then reaches the mapping without any of ByteArray's methods; ENS's
 * `byteArrayFromHex` is written that way, and so is every subgraph that copied
 * it. A plain Uint8Array can only have been meant as one of graph-ts' byte
 * types, so it is retagged as the most derived one — `Bytes` adds no instance
 * members over `ByteArray`, so this satisfies both spellings.
 */
export function changetype<T>(value: unknown): T {
  if (value instanceof Uint8Array && Object.getPrototypeOf(value) === Uint8Array.prototype) {
    Object.setPrototypeOf(value, Bytes.prototype);
  }
  return value as T;
}

// `changetype<GeneratedTuple>(result[0].toTuple())` is a pointer reinterpret
// in AssemblyScript; in JS the named getters live on the generated class.
// The load hook rewrites that call to this helper so `.value` etc. resolve.
export function retagChangetype(ctor: unknown, value: unknown, keepInstances = false): unknown {
  if (value !== null && typeof value === "object" && typeof ctor === "function") {
    if (keepInstances) {
      // An `as` cast to a class the value already is, or extends, is an
      // upcast: the value keeps the getters of its own class.
      if (value instanceof (ctor as Function)) return value;
      // Across to a sibling — GMX casts one EventLog1 to EventLog2 for a
      // helper — AssemblyScript reads the same object through the other
      // class and leaves the original as it was, so the original isn't
      // retagged: the cast reads a copy.
      const current = Object.getPrototypeOf(value)?.constructor;
      if (typeof current === "function" && !((ctor as Function).prototype instanceof current)) {
        return Object.defineProperties(
          Object.create((ctor as Function).prototype),
          Object.getOwnPropertyDescriptors(value),
        );
      }
    }
    const proto = (ctor as Function).prototype;
    if (proto) Object.setPrototypeOf(value, proto);
  }
  return changetype(value);
}

/**
 * `x.toTupleArray<Struct>()`: each element is a `Struct` in AssemblyScript, and
 * graph codegen's getters live on that class. A matrix nests the arrays.
 */
export function retagEach(ctor: unknown, values: unknown): unknown {
  if (!Array.isArray(values)) return values;
  for (const value of values) {
    if (value instanceof EthereumTuple) retagChangetype(ctor, value, true);
    else if (Array.isArray(value)) retagEach(ctor, value);
  }
  return values;
}

/**
 * AssemblyScript's primitives are namespaces as well as types: `i32.MAX_VALUE`
 * reads a bound, `i32(x)` truncates to one. Both are ordinary source in a
 * mapping and neither exists in JavaScript.
 *
 * The 64-bit pair carries values a double can't hold, so it works in bigints;
 * everything else stays a number, which is what the rest of the shim converts.
 */
function integerNamespace(name: string, bits: number, signed: boolean) {
  const min = signed ? -(2 ** (bits - 1)) : 0;
  const max = signed ? 2 ** (bits - 1) - 1 : 2 ** bits - 1;
  const cast = (value: number) => {
    const truncated = Math.trunc(Number(value)) || 0;
    const span = 2 ** bits;
    const wrapped = ((truncated % span) + span) % span;
    return wrapped > max ? wrapped - span : wrapped;
  };
  return strictNamespace(
    name,
    Object.assign(cast, { MIN_VALUE: min, MAX_VALUE: max, parseInt: (text: string, radix = 0) => cast(parseAsInteger(text, radix) as number) }),
  );
}

/** AssemblyScript's `I32.parseInt(text, radix)`: radix 0 reads a 0x/0b/0o prefix; garbage is 0. */
function parseAsInteger(text: string, radix: number): number {
  let rest = String(text).trim();
  let sign = 1;
  if (rest.startsWith("-")) {
    sign = -1;
    rest = rest.slice(1);
  } else if (rest.startsWith("+")) rest = rest.slice(1);
  let base = radix;
  const prefixed = /^0([xXbBoO])/.exec(rest);
  if (prefixed && (base === 0 || base === { x: 16, b: 2, o: 8 }[prefixed[1].toLowerCase() as "x" | "b" | "o"])) {
    base = { x: 16, b: 2, o: 8 }[prefixed[1].toLowerCase() as "x" | "b" | "o"];
    rest = rest.slice(2);
  }
  if (base === 0) base = 10;
  const parsed = Number.parseInt(rest, base);
  return Number.isNaN(parsed) ? 0 : sign * parsed;
}

function bigIntegerNamespace(name: string, signed: boolean) {
  const min = signed ? -(2n ** 63n) : 0n;
  const max = signed ? 2n ** 63n - 1n : 2n ** 64n - 1n;
  const cast = (value: unknown) => {
    const raw = typeof value === "bigint" ? value : BigInt(Math.trunc(Number(value)) || 0);
    // AssemblyScript truncates a cast to the target width rather than widening.
    return signed ? BigInt.asIntN(64, raw) : BigInt.asUintN(64, raw);
  };
  return strictNamespace(
    name,
    Object.assign(cast, { MIN_VALUE: min, MAX_VALUE: max, parseInt: (text: string, radix = 0) => cast(BigInt(parseAsInteger(text, radix))) }),
  );
}

function floatNamespace(name: string, single: boolean) {
  const cast = (value: unknown) => (single ? Math.fround(Number(value)) : Number(value));
  return strictNamespace(
    name,
    Object.assign(cast, {
      // AssemblyScript's MIN_VALUE is the most negative finite value, not the
      // smallest positive one JavaScript names.
      MIN_VALUE: single ? -3.4028234663852886e38 : -Number.MAX_VALUE,
      MAX_VALUE: single ? 3.4028234663852886e38 : Number.MAX_VALUE,
      EPSILON: single ? 1.1920928955078125e-7 : Number.EPSILON,
      MIN_SAFE_INTEGER: single ? -16777215 : Number.MIN_SAFE_INTEGER,
      MAX_SAFE_INTEGER: single ? 16777215 : Number.MAX_SAFE_INTEGER,
      NaN: Number.NaN,
      POSITIVE_INFINITY: Number.POSITIVE_INFINITY,
      NEGATIVE_INFINITY: Number.NEGATIVE_INFINITY,
    }),
  );
}

// ---------------------------------------------------------------------------
// The rest of graph-ts 0.38's export list
// ---------------------------------------------------------------------------

/**
 * graph-ts declares these as AssemblyScript type aliases (`type Timestamp =
 * i64`). AssemblyScript erases them, but the JavaScript the addon makes of a
 * mapping still imports them by name (xmtp's `import { Timestamp } from
 * "@graphprotocol/graph-ts"`), and an ES module import of a name the module
 * lacks is a link error. They hold nothing; a mapping only writes them as types.
 */
export const Timestamp = undefined;
export const Int8 = undefined;
export const ValuePayload = undefined;
export const JSONValuePayload = undefined;
export const YAMLValuePayload = undefined;

/** Starknet's field element: `Felt.intoBigInt()` reads its bytes as a number. */
export class Felt extends Bytes {
  intoBigInt(): BigInt_ {
    return BigInt_.fromUnsignedBytes(new ByteArray(this).reverse() as ByteArray);
  }
}

/** The discriminants graph-node reads an AssemblyScript object's class by. */
export enum TypeId {
  String = 0,
  ArrayBuffer = 1,
  Int8Array = 2,
  Int16Array = 3,
  Int32Array = 4,
  Int64Array = 5,
  Uint8Array = 6,
  Uint16Array = 7,
  Uint32Array = 8,
  Uint64Array = 9,
  Float32Array = 10,
  Float64Array = 11,
  BigDecimal = 12,
  ArrayBool = 13,
  ArrayUint8Array = 14,
  ArrayEthereumValue = 15,
  ArrayStoreValue = 16,
  ArrayJsonValue = 17,
  ArrayString = 18,
  YamlTypedMapValueValue = 5503,
  YamlArrayValue = 5504,
  YamlArrayTypedMapEntryValueValue = 5505,
  YamlWrappedValue = 5506,
  YamlResultValueBool = 5507,
}

/** AssemblyScript's `idof<T>()` for a graph-node type: a number the host reads. Nothing here reads it. */
export function id_of_type(typeId: TypeId): number {
  return typeId;
}

/** Hands the host an object by pointer; there is no wasm memory here to allocate in. */
export function allocate(_size: number): number {
  throw unsupported("allocate(), which hands the graph-node host a raw memory block", "a mapping handler");
}

/** A chain whose subgraphs this indexes no part of: naming a member is the error. */
function otherEcosystem(name: string, ecosystem: string) {
  return new Proxy(
    {},
    {
      get(_target, prop) {
        if (typeof prop === "symbol" || prop === "then" || prop === "toJSON") return undefined;
        throw unsupported(`${ecosystem} subgraphs — Envio Subgraph indexes EVM chains`, `${name}.${String(prop)}`);
      },
    },
  );
}

// Typed as graph-ts' own, so a mapping's types agree and only a read refuses.
export const near = otherEcosystem("near", "NEAR") as unknown as typeof GraphTsTypes.near;
export const cosmos = otherEcosystem("cosmos", "Cosmos") as unknown as typeof GraphTsTypes.cosmos;
export const starknet = otherEcosystem("starknet", "Starknet") as unknown as typeof GraphTsTypes.starknet;

/**
 * AssemblyScript's fixed-length array, which as-base64 builds its lookup table
 * from: `StaticArray.fromArray<u8>([...])`. A JavaScript Array holds the same.
 */
class StaticArray<T> extends Array<T> {
  static fromArray<T>(values: T[]): StaticArray<T> {
    const array = new StaticArray<T>(values.length);
    for (let index = 0; index < values.length; index++) array[index] = values[index];
    return array;
  }
}

export const assemblyScriptPrimitives: Record<string, unknown> = {
  StaticArray,
  i8: integerNamespace("i8", 8, true),
  u8: integerNamespace("u8", 8, false),
  i16: integerNamespace("i16", 16, true),
  u16: integerNamespace("u16", 16, false),
  i32: integerNamespace("i32", 32, true),
  u32: integerNamespace("u32", 32, false),
  isize: integerNamespace("isize", 32, true),
  usize: integerNamespace("usize", 32, false),
  i64: bigIntegerNamespace("i64", true),
  u64: bigIntegerNamespace("u64", false),
  f32: floatNamespace("f32", true),
  f64: floatNamespace("f64", false),
};
// The wrapper classes (`I32.parseInt(...)`, `U64.MAX_VALUE`) are the same
// namespaces under their capitalised names.
for (const name of Object.keys(assemblyScriptPrimitives)) {
  if (/^[iuf]\d+$/.test(name)) assemblyScriptPrimitives[name.toUpperCase()] = assemblyScriptPrimitives[name];
}

// ---------------------------------------------------------------------------
// Host namespaces the generated declarations re-export
//
// A mapping importing one of these fails at ESM link time if it isn't exported,
// which is a missing-export error naming nothing useful. Exporting them means an
// unsupported one refuses by name like everything else.
// ---------------------------------------------------------------------------

/** graph-ts' BigInt, whether the caller passed one or the bytes of one. */
function asGraphBigInt(value: Uint8Array): BigInt_ {
  return value instanceof BigInt_ ? value : new BigInt_(fromLittleEndian(value, true));
}

const typeConversionImpl = {
  bytesToString: (bytes: Uint8Array) => new ByteArray(bytes).toString(),
  bytesToHex: (bytes: Uint8Array) => new ByteArray(bytes).toHexString(),
  // graph-ts types the argument as the byte array a BigInt is in
  // AssemblyScript. This one carries its value instead of laying those bytes
  // out (see `BigInt_`), so reading it as bytes would answer zero for every
  // input.
  bigIntToString: (value: Uint8Array) => asGraphBigInt(value).toString(),
  bigIntToHex: (value: Uint8Array) => asGraphBigInt(value).toHexString(),
  stringToH160: (value: string) => Address.fromString(value) as Bytes,
  bytesToBase58: (_: Uint8Array): string => {
    throw unsupported("typeConversion.bytesToBase58", "a mapping handler");
  },
};

export const typeConversion = strictNamespace("typeConversion", typeConversionImpl);

const bigIntImpl = {
  plus: (x: BigInt_, y: BigInt_) => x.plus(y),
  minus: (x: BigInt_, y: BigInt_) => x.minus(y),
  times: (x: BigInt_, y: BigInt_) => x.times(y),
  dividedBy: (x: BigInt_, y: BigInt_) => x.div(y),
  dividedByDecimal: (x: BigInt_, y: BigDecimal) => x.toBigDecimal().div(y),
  mod: (x: BigInt_, y: BigInt_) => x.mod(y),
  pow: (x: BigInt_, exp: number) => x.pow(exp),
  fromString: (value: string) => BigInt_.fromString(value),
  bitOr: (x: BigInt_, y: BigInt_) => x.bitOr(y),
  bitAnd: (x: BigInt_, y: BigInt_) => x.bitAnd(y),
  leftShift: (x: BigInt_, bits: number) => x.leftShift(bits),
  rightShift: (x: BigInt_, bits: number) => x.rightShift(bits),
};

export const bigInt = strictNamespace("bigInt", bigIntImpl);

const bigDecimalImpl = {
  plus: (x: BigDecimal, y: BigDecimal) => x.plus(y),
  minus: (x: BigDecimal, y: BigDecimal) => x.minus(y),
  times: (x: BigDecimal, y: BigDecimal) => x.times(y),
  dividedBy: (x: BigDecimal, y: BigDecimal) => x.div(y),
  equals: (x: BigDecimal, y: BigDecimal) => x.equals(y),
  toString: (value: BigDecimal) => value.toString(),
  fromString: (value: string) => BigDecimal.fromString(value),
};

export const bigDecimal = strictNamespace("bigDecimal", bigDecimalImpl);

export function concat(a: ByteArray, b: ByteArray): ByteArray {
  return a.concat(b);
}

export function parseCSV(csv: string): string[] {
  return csv.split(",").map(field => field.trim());
}

/** Restores the multihash prefix an IPFS hash loses when stored in a bytes32. */
export function addQm(a: ByteArray): ByteArray {
  return ByteArray.fromHexString("0x1220").concat(a);
}

export enum YAMLValueKind {
  NULL = 0,
  BOOL = 1,
  NUMBER = 2,
  STRING = 3,
  ARRAY = 4,
  OBJECT = 5,
  TAGGED = 6,
}

/**
 * graph-ts' YAML value, over graph-node's `serde_yaml::Value`: numbers are kept
 * as the text they print as, an object's keys are YAML values themselves, and a
 * `!tag` wraps its value.
 */
export class YAMLValue {
  constructor(
    public kind: YAMLValueKind,
    public data: any,
  ) {}

  static newNull(): YAMLValue {
    return new YAMLValue(YAMLValueKind.NULL, 0);
  }
  static newBool(data: boolean): YAMLValue {
    return new YAMLValue(YAMLValueKind.BOOL, data);
  }
  static newI64(data: bigint): YAMLValue {
    return new YAMLValue(YAMLValueKind.NUMBER, data.toString());
  }
  static newU64(data: bigint): YAMLValue {
    return new YAMLValue(YAMLValueKind.NUMBER, data.toString());
  }
  static newF64(data: number): YAMLValue {
    return new YAMLValue(YAMLValueKind.NUMBER, String(data));
  }
  static newBigInt(data: BigInt_): YAMLValue {
    return new YAMLValue(YAMLValueKind.STRING, data.toString());
  }
  static newString(data: string): YAMLValue {
    return new YAMLValue(YAMLValueKind.STRING, data);
  }
  static newArray(data: YAMLValue[]): YAMLValue {
    return new YAMLValue(YAMLValueKind.ARRAY, data);
  }
  static newObject(data: TypedMap<YAMLValue, YAMLValue>): YAMLValue {
    const map = new YAMLMap();
    for (const entry of data.entries) map.set(entry.key, entry.value);
    return new YAMLValue(YAMLValueKind.OBJECT, map);
  }
  static newTagged(tag: string, value: YAMLValue): YAMLValue {
    return new YAMLValue(YAMLValueKind.TAGGED, new YAMLTaggedValue(tag, value));
  }

  isNull(): boolean {
    return this.kind === YAMLValueKind.NULL;
  }
  isBool(): boolean {
    return this.kind === YAMLValueKind.BOOL;
  }
  isNumber(): boolean {
    return this.kind === YAMLValueKind.NUMBER;
  }
  isString(): boolean {
    return this.kind === YAMLValueKind.STRING;
  }
  isArray(): boolean {
    return this.kind === YAMLValueKind.ARRAY;
  }
  isObject(): boolean {
    return this.kind === YAMLValueKind.OBJECT;
  }
  isTagged(): boolean {
    return this.kind === YAMLValueKind.TAGGED;
  }

  toBool(): boolean {
    assertYaml(this.isBool(), "YAML value is not a boolean");
    return this.data === true;
  }
  toNumber(): string {
    assertYaml(this.isNumber(), "YAML value is not a number");
    return this.data as string;
  }
  toI64(): bigint {
    return BigInt.asIntN(64, BigInt(this.toNumber()));
  }
  toU64(): bigint {
    return BigInt.asUintN(64, BigInt(this.toNumber()));
  }
  toF64(): number {
    return Number(this.toNumber());
  }
  toBigInt(): BigInt_ {
    assertYaml(this.isNumber() || this.isString(), "YAML value is not numeric");
    return BigInt_.fromString(this.data as string);
  }
  toString(): string {
    assertYaml(this.isString(), "YAML value is not a string");
    return this.data as string;
  }
  toArray(): YAMLValue[] {
    assertYaml(this.isArray(), "YAML value is not an array");
    return this.data as YAMLValue[];
  }
  toObject(): TypedMap<YAMLValue, YAMLValue> {
    assertYaml(this.isObject(), "YAML value is not an object");
    return this.data as TypedMap<YAMLValue, YAMLValue>;
  }
  toTagged(): YAMLTaggedValue {
    assertYaml(this.isTagged(), "YAML value is not tagged");
    return this.data as YAMLTaggedValue;
  }

  /** graph-ts' `==` overload: structural, so a `TypedMap` keyed by YAML values finds its key. */
  equals(other: YAMLValue): boolean {
    return YAMLValue.eq(this, other);
  }
  static eq(a: YAMLValue, b: YAMLValue): boolean {
    if (a.isBool() && b.isBool()) return a.data === b.data;
    if (a.isNumber() && b.isNumber()) return a.data === b.data;
    if (a.isString() && b.isString()) return a.data === b.data;
    if (a.isArray() && b.isArray()) {
      const left = a.toArray();
      const right = b.toArray();
      return left.length === right.length && left.every((item, index) => YAMLValue.eq(item, right[index]));
    }
    if (a.isObject() && b.isObject()) {
      const left = a.toObject();
      const right = b.toObject();
      return (
        left.entries.length === right.entries.length &&
        left.entries.every((entry) => {
          const other = right.get(entry.key);
          return other !== null && YAMLValue.eq(entry.value, other);
        })
      );
    }
    if (a.isTagged() && b.isTagged()) return YAMLTaggedValue.eq(a.toTagged(), b.toTagged());
    return false;
  }
  static ne(a: YAMLValue | null, b: YAMLValue | null): boolean {
    if (!a || !b) return true;
    return !YAMLValue.eq(a, b);
  }

  /** `value["key"]` on an object, `value["0"]` on an array; aborts when the key is absent. */
  get(index: string): YAMLValue {
    assertYaml(this.isArray() || this.isObject(), "YAML value can not be accessed by index");
    if (this.isArray()) {
      const item = this.toArray()[Number.parseInt(index, 10)];
      assertYaml(item !== undefined, "Array index out of range");
      return item;
    }
    return this.toObject().mustGet(YAMLValue.newString(index));
  }
}

/** AssemblyScript's `==` on YAML keys compares their content, which is how `toObject().get(newString("k"))` finds "k". */
class YAMLMap extends TypedMap<YAMLValue, YAMLValue> {
  getEntry(key: YAMLValue): TypedMapEntry<YAMLValue, YAMLValue> | null {
    return this.entries.find((entry) => YAMLValue.eq(entry.key, key)) ?? null;
  }
}

export class YAMLTaggedValue {
  constructor(
    public tag: string,
    public value: YAMLValue,
  ) {}
  equals(other: YAMLTaggedValue): boolean {
    return YAMLTaggedValue.eq(this, other);
  }
  static eq(a: YAMLTaggedValue, b: YAMLTaggedValue): boolean {
    return a.tag === b.tag && YAMLValue.eq(a.value, b.value);
  }
  static ne(a: YAMLTaggedValue | null, b: YAMLTaggedValue | null): boolean {
    if (!a || !b) return true;
    return !YAMLTaggedValue.eq(a, b);
  }
}

function assertYaml(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

/** graph-node refuses a document over this many bytes. */
const YAML_MAX_SIZE_BYTES = 10_000_000;

/**
 * A parsed node as graph-node hands it to the mapping. Numbers keep the text
 * serde_yaml prints them as (an integer as its digits, a float with its
 * fraction), a mapping key is a YAML value of its own, and an alias is its
 * target.
 */
function yamlFromNode(node: unknown, document: Document): YAMLValue {
  if (isAlias(node)) {
    return yamlFromNode(node.resolve(document), document);
  }
  if (isMap(node)) {
    const map = new YAMLMap();
    for (const pair of node.items) {
      map.set(yamlFromNode(pair.key, document), yamlFromNode(pair.value, document));
    }
    return taggedOr(node, YAMLValue.newObject(map));
  }
  if (isSeq(node)) {
    return taggedOr(node, YAMLValue.newArray(node.items.map((item) => yamlFromNode(item, document))));
  }
  if (isScalar(node)) {
    const value = node.value;
    let result: YAMLValue;
    if (value === null || value === undefined) result = YAMLValue.newNull();
    else if (typeof value === "boolean") result = YAMLValue.newBool(value);
    else if (typeof value === "bigint") result = new YAMLValue(YAMLValueKind.NUMBER, value.toString());
    else if (typeof value === "number") {
      const source = (node as { srcToken?: { source?: string } }).srcToken?.source ?? "";
      // YAML `1.0` is the float 1.0, which serde_yaml prints as such.
      const isFloat = /[.eE]/.test(source) && Number.isFinite(value);
      const text = Number.isNaN(value)
        ? "NaN"
        : value === Infinity
          ? "inf"
          : value === -Infinity
            ? "-inf"
            : isFloat && Number.isInteger(value)
              ? `${value}.0`
              : String(value);
      result = new YAMLValue(YAMLValueKind.NUMBER, text);
    } else result = YAMLValue.newString(String(value));
    return taggedOr(node, result);
  }
  return YAMLValue.newNull();
}

/** A local tag (`!Ref x`) wraps its value; the core tags (`!!str`) are the value itself. */
function taggedOr(node: unknown, value: YAMLValue): YAMLValue {
  const tag = (node as { tag?: string }).tag;
  if (typeof tag === "string" && tag.startsWith("!") && !tag.startsWith("!!")) {
    return YAMLValue.newTagged(tag, value);
  }
  return value;
}

function parseYaml(text: string): YAMLValue {
  if (Buffer.byteLength(text) > YAML_MAX_SIZE_BYTES) {
    throw new Error(`YAML size exceeds max size of ${YAML_MAX_SIZE_BYTES} bytes`);
  }
  const document = parseDocument(text, { intAsBigInt: true, keepSourceTokens: true });
  if (document.errors.length > 0) {
    throw new Error(`failed to parse YAML from bytes: ${document.errors[0].message}`);
  }
  return yamlFromNode(document.contents, document);
}

const yamlImpl = {
  fromBytes: (bytes: Bytes): YAMLValue => parseYaml(utf8Decoder.decode(bytes)),
  try_fromBytes: (bytes: Bytes): Result<YAMLValue, boolean> => tryParse(() => parseYaml(utf8Decoder.decode(bytes))),
  fromString: (text: string): YAMLValue => parseYaml(text),
  try_fromString: (text: string): Result<YAMLValue, boolean> => tryParse(() => parseYaml(text)),
};

export const yaml = strictNamespace("yaml", yamlImpl);
