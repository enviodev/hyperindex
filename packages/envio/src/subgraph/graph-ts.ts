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

import BigNumber from "bignumber.js";
import { keccak256 as viemKeccak256, toHex, hexToBytes, decodeAbiParameters } from "viem";
import { currentScope } from "./scope.ts";
import {
  PROTOTYPE_PASSTHROUGH,
  refusedGetter,
  strictNamespace,
  unsupported,
  unknown,
} from "./errors.ts";

// ---------------------------------------------------------------------------
// Byte values
// ---------------------------------------------------------------------------

export class ByteArray extends Uint8Array {
  static fromHexString(hex: string): ByteArray {
    const normalized = hex.startsWith("0x") ? hex : "0x" + hex;
    return new ByteArray(hexToBytes(normalized as `0x${string}`));
  }
  static fromUTF8(input: string): ByteArray {
    return new ByteArray(new TextEncoder().encode(input));
  }
  static fromI32(value: number): ByteArray {
    return ByteArray.fromHexString(toHex(value, { size: 4 }));
  }
  static fromBigInt(value: BigInt_): ByteArray {
    return ByteArray.fromHexString(toHex(value.valueOf(), { size: 32 }));
  }
  static fromUint8Array(bytes: Uint8Array): ByteArray {
    return new ByteArray(bytes);
  }
  static fromU32(value: number): ByteArray {
    return ByteArray.fromI32(value);
  }
  static fromI64(value: bigint): ByteArray {
    return ByteArray.fromHexString(toHex(value, { size: 8 }));
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
  toString(): string {
    return this.toHexString();
  }
  toBase58(): string {
    throw unsupported("ByteArray.toBase58", "a mapping handler");
  }
  toU32(): number {
    return Number(BigInt(this.toHexString()));
  }
  toI32(): number {
    return this.toU32();
  }
  toBigInt(): BigInt_ {
    return BigInt_.fromString(this.toHexString());
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
    return BigInt(this.toHexString());
  }
  toU64(): bigint {
    return this.toI64();
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
    if (!/^0x[0-9a-fA-F]{40}$/.test(address)) {
      throw new Error(`Address.fromString: ${address} is not a valid 20-byte hex address`);
    }
    return new Address(ByteArray.fromHexString(address.toLowerCase()));
  }
  static fromBytes(bytes: Bytes): Address {
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

class BigInt_ extends Uint8Array {
  readonly value: bigint;

  constructor(value: bigint) {
    // The bytes are deliberately left empty. Arithmetic, comparison and every
    // `to*` run off `value`; materialising the two's-complement representation
    // on construction cost ~7% of indexing CPU, and nothing in a mapping reads
    // a BigInt as bytes — graph codegen never emits it, and the conversions
    // that would (`toHexString`, `toI32`) are overridden here.
    super(0);
    this.value = value;
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
    return new BigInt_(typeof raw === "bigint" ? raw : BigInt(Math.trunc(raw as number)));
  }
  static fromU32(value: number): BigInt_ {
    return BigInt_.fromI32(value);
  }
  static fromI64(value: bigint | number): BigInt_ {
    return new BigInt_(BigInt(value));
  }
  static fromU64(value: bigint | number): BigInt_ {
    return new BigInt_(BigInt(value));
  }
  static fromString(value: string): BigInt_ {
    return new BigInt_(BigInt(value));
  }
  static fromByteArray(bytes: ByteArray): BigInt_ {
    return BigInt_.fromString(bytes.toHexString());
  }
  static fromUnsignedBytes(bytes: ByteArray): BigInt_ {
    return BigInt_.fromByteArray(bytes);
  }
  static fromSignedBytes(bytes: Bytes): BigInt_ {
    return BigInt_.fromByteArray(bytes);
  }
  static zero(): BigInt_ {
    return new BigInt_(0n);
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
    return Number(this.value);
  }
  toU32(): number {
    return Number(this.value);
  }
  toI64(): bigint {
    return this.value;
  }
  toBigDecimal(): BigDecimal {
    return new BigDecimal(new BigNumber(this.value.toString()));
  }

  plus(other: BigInt_): BigInt_ {
    return new BigInt_(this.value + other.value);
  }
  minus(other: BigInt_): BigInt_ {
    return new BigInt_(this.value - other.value);
  }
  times(other: BigInt_): BigInt_ {
    return new BigInt_(this.value * other.value);
  }
  div(other: BigInt_): BigInt_ {
    return new BigInt_(this.value / other.value);
  }
  mod(other: BigInt_): BigInt_ {
    return new BigInt_(this.value % other.value);
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
    return this.value === other.value;
  }
  notEqual(other: BigInt_): boolean {
    return this.value !== other.value;
  }
  lt(other: BigInt_): boolean {
    return this.value < other.value;
  }
  le(other: BigInt_): boolean {
    return this.value <= other.value;
  }
  gt(other: BigInt_): boolean {
    return this.value > other.value;
  }
  ge(other: BigInt_): boolean {
    return this.value >= other.value;
  }
  isZero(): boolean {
    return this.value === 0n;
  }
  isI32(): boolean {
    return this.value >= -2147483648n && this.value <= 2147483647n;
  }
  toU64(): bigint {
    return this.value;
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

export class BigDecimal {
  readonly value: BigNumber;

  constructor(value: BigNumber | BigInt_ | string | number) {
    if (value instanceof BigNumber) {
      this.value = value;
    } else if (value instanceof BigInt_) {
      this.value = new BigNumber(value.toString());
    } else {
      this.value = new BigNumber(value as any);
    }
  }

  static fromString(value: string): BigDecimal {
    return new BigDecimal(new BigNumber(value));
  }
  static zero(): BigDecimal {
    return new BigDecimal(new BigNumber(0));
  }
  static compare(a: BigDecimal, b: BigDecimal): number {
    return a.value.comparedTo(b.value);
  }

  toString(): string {
    return this.value.toFixed();
  }
  toBigInt(): BigInt_ {
    return BigInt_.fromString(this.value.integerValue(BigNumber.ROUND_DOWN).toFixed());
  }
  plus(other: BigDecimal): BigDecimal {
    return new BigDecimal(this.value.plus(other.value));
  }
  minus(other: BigDecimal): BigDecimal {
    return new BigDecimal(this.value.minus(other.value));
  }
  times(other: BigDecimal): BigDecimal {
    return new BigDecimal(this.value.times(other.value));
  }
  div(other: BigDecimal): BigDecimal {
    return new BigDecimal(this.value.div(other.value));
  }
  equals(other: BigDecimal): boolean {
    return this.value.isEqualTo(other.value);
  }
  notEqual(other: BigDecimal): boolean {
    return !this.value.isEqualTo(other.value);
  }
  lt(other: BigDecimal): boolean {
    return this.value.isLessThan(other.value);
  }
  le(other: BigDecimal): boolean {
    return this.value.isLessThanOrEqualTo(other.value);
  }
  gt(other: BigDecimal): boolean {
    return this.value.isGreaterThan(other.value);
  }
  ge(other: BigDecimal): boolean {
    return this.value.isGreaterThanOrEqualTo(other.value);
  }
  neg(): BigDecimal {
    return new BigDecimal(this.value.negated());
  }
  truncate(decimals: number): BigDecimal {
    return new BigDecimal(this.value.decimalPlaces(decimals, BigNumber.ROUND_DOWN));
  }
  // graph-ts stores a decimal as `digits * 10 ** exp`.
  get digits(): BigInt_ {
    const [coefficient, exponent] = this.value.toFixed().split(".");
    const scaled = (coefficient ?? "0") + (exponent ?? "");
    return BigInt_.fromString(scaled === "" || scaled === "-" ? "0" : scaled);
  }
  get exp(): BigInt_ {
    const fraction = this.value.toFixed().split(".")[1] ?? "";
    return BigInt_.fromI32(-fraction.length);
  }
}

// ---------------------------------------------------------------------------
// TypedMap / Value / Entity
// ---------------------------------------------------------------------------

export class TypedMapEntry<K, V> {
  constructor(
    public key: K,
    public value: V,
  ) {}
}

export class TypedMap<K, V> {
  entries: TypedMapEntry<K, V>[] = [];

  set(key: K, value: V): void {
    const entry = this.getEntry(key);
    if (entry) {
      entry.value = value;
    } else {
      this.entries.push(new TypedMapEntry(key, value));
    }
  }
  getEntry(key: K): TypedMapEntry<K, V> | null {
    return this.entries.find((entry) => entry.key === key) ?? null;
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
    for (const entity of sources) {
      for (const entry of entity.entries) {
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
 * `graph codegen` emits `changetype<Pair | null>(store.get(...))`, and
 * `changetype` erases its type argument, so a loaded entity reaches the mapping
 * without the generated prototype that carries `pair.token0`. Falling through to
 * the stored field — typed by the `Value` kind, which is what the generated
 * getter would have returned — is what makes that code work here. A name the
 * entity doesn't hold is still refused.
 */
/**
 * The entity type a loaded row came from. `changetype` erased the generated
 * prototype, and with it the `save()` that knows which table to write back to,
 * so the type is remembered on the instance instead.
 */
const ENTITY_TYPE = Symbol("envio.entityType");

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
          storeImpl.set(
            entityType,
            id.kind === ValueKind.BYTES ? id.toBytes().toHexString() : id.toString(),
            receiver,
          );
        };
      }
    }
    const stored = receiver instanceof Entity ? receiver.get(prop as string) : null;
    if (stored !== null) {
      return valueToNative(stored);
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

/** graph-ts `Value`s -> the plain scalars envio stores. */
function toRow(entityType: string, entity: Entity): Record<string, unknown> {
  const { schema } = currentScope();
  const timestampFields = new Set(schema.timestampFields[entityType] ?? []);
  // graph-ts holds a relation as the related entity's id under the field's own
  // name; envio's column for it is `<field>_id`.
  const refFields = new Set(schema.entityRefFields[entityType] ?? []);
  const row: Record<string, unknown> = {};
  for (const entry of entity.entries) {
    const column = refFields.has(entry.key) ? `${entry.key}_id` : entry.key;
    row[column] = timestampFields.has(entry.key)
      ? new Date(Number(entry.value.toTimestamp() / 1000n))
      : fromValue(entry.value);
  }
  return row;
}

function fromValue(value: Value): unknown {
  switch (value.kind) {
    case ValueKind.NULL:
      return null;
    case ValueKind.BYTES:
      return value.toBytes().toHexString();
    case ValueKind.BIGINT:
      return value.toBigInt().valueOf();
    case ValueKind.INT8:
    case ValueKind.TIMESTAMP:
      return BigInt(value.data as any);
    case ValueKind.BIGDECIMAL:
      return value.toBigDecimal().value;
    case ValueKind.ARRAY:
      return value.toArray().map(fromValue);
    default:
      return value.data;
  }
}

/** envio rows -> graph-ts `Value`s. */
function toEntity(entityType: string, row: Record<string, unknown> | undefined | null): Entity | null {
  if (row === undefined || row === null) {
    return null;
  }
  const { schema } = currentScope();
  const timestampFields = new Set(schema.timestampFields[entityType] ?? []);
  const refFields = new Set(schema.entityRefFields[entityType] ?? []);
  const entity = new Entity();
  Object.defineProperty(entity, ENTITY_TYPE, { value: entityType });
  for (const [column, value] of Object.entries(row)) {
    const key =
      column.endsWith("_id") && refFields.has(column.slice(0, -3))
        ? column.slice(0, -3)
        : column;
    entity.set(
      key,
      timestampFields.has(key)
        ? Value.fromTimestamp(BigInt((value as Date).getTime()) * 1000n)
        : toValue(value),
    );
  }
  return entity;
}

function toValue(value: unknown): Value {
  if (value === null || value === undefined) return Value.fromNull();
  if (typeof value === "string") return Value.fromString(value);
  if (typeof value === "boolean") return Value.fromBoolean(value);
  if (typeof value === "number") return Value.fromI32(value);
  if (typeof value === "bigint") return Value.fromBigInt(new BigInt_(value));
  if (Array.isArray(value)) return Value.fromArray(value.map(toValue));
  if (value instanceof BigNumber) return Value.fromBigDecimal(new BigDecimal(value));
  return Value.fromString(String(value));
}

function entityContext(entityType: string) {
  const { context } = currentScope();
  const table = context[entityType];
  if (!table) {
    throw unknown(`the entity ${entityType}`, "a mapping handler");
  }
  return table;
}

const storeImpl = {
  get(entityType: string, id: string): Entity | null {
    const { mode } = currentScope();
    // Nothing has been written at fetch time, so the register pass reads null
    // rather than a value that would differ between the two passes.
    if (mode === "register") return null;
    return toEntity(entityType, entityContext(entityType).getSync(id));
  },
  get_in_block(entityType: string, id: string): Entity | null {
    const { mode } = currentScope();
    if (mode === "register") return null;
    return toEntity(entityType, entityContext(entityType).getInBlockSync(id));
  },
  set(entityType: string, id: string, data: Entity): void {
    const { mode } = currentScope();
    if (mode === "register") return;
    const row = toRow(entityType, data);
    row.id = id;
    entityContext(entityType).set(row);
  },
  remove(entityType: string, id: string): void {
    const { mode } = currentScope();
    if (mode === "register") return;
    entityContext(entityType).deleteUnsafe(id);
  },
  loadRelated(entityType: string, id: string, field: string): Entity[] {
    const { mode } = currentScope();
    if (mode === "register") return [];
    const rows = entityContext(entityType).getWhereSync({ [field]: { _eq: id } });
    return rows.map((row: any) => toEntity(entityType, row) as Entity);
  },
};

export const store = strictNamespace("store", storeImpl);

// ---------------------------------------------------------------------------
// ethereum
// ---------------------------------------------------------------------------

export class EthereumValue extends Value {}

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

  call(_returnTypes: string, functionSignature: string, params: EthereumValue[]): EthereumValue[] {
    return callContract(this, functionSignature, params, false) as EthereumValue[];
  }

  tryCall(
    _returnTypes: string,
    functionSignature: string,
    params: EthereumValue[],
  ): CallResult<EthereumValue[]> {
    return callContract(this, functionSignature, params, true) as CallResult<EthereumValue[]>;
  }
}

/**
 * Contract calls go through the shim's call hook, installed by the runtime so
 * this module stays free of envio imports. A transport failure is not a revert:
 * it throws as the handler error (which envio retries) so a flaky RPC never
 * fabricates `{reverted: true}` data.
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
    functionSignature.split("(")[0],
    functionSignature,
    params,
  );
  // A suspend thrown by the underlying effect must escape `try_` too: it isn't
  // a revert, it's "not resolved yet".
  const result = callHook(call);
  if (isTry) {
    return result.reverted
      ? new CallResult(true, null)
      : CallResult.fromValue((result.value ?? []).map(toEthereumValue));
  }
  if (result.reverted) {
    throw new Error(`Call to ${contract._name}.${functionSignature} reverted`);
  }
  return (result.value ?? []).map(toEthereumValue);
}

function toEthereumValue(value: unknown): EthereumValue {
  return toValue(value) as EthereumValue;
}

/** A graph-ts value as the plain JS an ABI encoder takes. */
export function valueToJs(value: Value): unknown {
  switch (value.kind) {
    case ValueKind.BYTES:
      return value.toBytes().toHexString();
    case ValueKind.BIGINT:
      return value.toBigInt().valueOf();
    case ValueKind.ARRAY:
      return value.toArray().map(valueToJs);
    case ValueKind.NULL:
      return null;
    default:
      return value.data;
  }
}

class EthereumBlock {
  constructor(
    public number: BigInt_,
    private _timestamp: () => BigInt_,
  ) {}
  get timestamp(): BigInt_ {
    return this._timestamp();
  }
}

class EthereumTransaction {
  constructor(private _fields: Record<string, unknown>) {
    Object.assign(this, _fields);
  }
}

/** graph-ts' own tag for an ABI value's Solidity type. */
export enum EthereumValueKind {
  ADDRESS = 0,
  FIXED_BYTES = 1,
  BYTES = 2,
  INT = 3,
  UINT = 4,
  BOOL = 5,
  STRING = 6,
  FIXED_ARRAY = 7,
  ARRAY = 8,
  TUPLE = 9,
}

class EthereumEventParam {
  constructor(
    public name: string,
    public value: EthereumValue,
  ) {}
}

/**
 * Only reachable through `event.receipt.logs`, which the runtime refuses on
 * access — envio's receipt selection carries the scalars, not the log list.
 * Declared so a mapping that names the type still compiles the way it does
 * against graph-ts.
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

class EthereumTransactionReceipt {
  constructor(
    public transactionHash: Bytes,
    public transactionIndex: BigInt_,
    public blockHash: Bytes,
    public blockNumber: BigInt_,
    public cumulativeGasUsed: BigInt_,
    public gasUsed: BigInt_,
    public contractAddress: Address,
    public logs: EthereumLog[],
    public status: BigInt_,
    public root: Bytes,
    public logsBloom: Bytes,
  ) {}
}

class EthereumCall {
  constructor(
    public to: Address,
    public from: Address,
    public block: EthereumBlock,
    public transaction: EthereumTransaction,
    public inputValues: EthereumEventParam[],
    public outputValues: EthereumEventParam[],
  ) {}
}

class EthereumEvent {
  constructor(
    public address: Address,
    public logIndex: BigInt_,
    public transactionLogIndex: never,
    public block: EthereumBlock,
    public transaction: EthereumTransaction,
    public parameters: unknown[],
  ) {}
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
  Tuple: Array,
  call(call: SmartContractCall): Value[] | null {
    const contract = new SmartContract(call.contractName, call.contractAddress);
    const result = callContract(contract, call.functionSignature, call.functionParams, true);
    return (result as CallResult<EthereumValue[]>).reverted
      ? null
      : (result as CallResult<EthereumValue[]>).value;
  },
  decode(types: string, data: Bytes): EthereumValue | null {
    try {
      const decoded = decodeAbiParameters(
        [{ type: types } as any],
        data.toHexString() as `0x${string}`,
      );
      return toEthereumValue(decoded[0]);
    } catch {
      return null;
    }
  },
  encode(_value: EthereumValue): Bytes | null {
    throw unsupported("ethereum.encode", "a mapping handler");
  },
  getBalance(address: Address): BigInt_ {
    return BigInt_.fromString(hostsOrThrow().getBalance(address.toHexString()));
  },
  hasCode(address: Address): CallResult<boolean> {
    return CallResult.fromValue(hostsOrThrow().hasCode(address.toHexString()));
  },
};

export const ethereum = strictNamespace("ethereum", ethereumImpl);

// ---------------------------------------------------------------------------
// dataSource + templates
// ---------------------------------------------------------------------------

let registerHook: ((templateName: string, address: string) => void) | null = null;

export function installRegisterHook(hook: typeof registerHook) {
  registerHook = hook;
}

export class DataSourceTemplate {
  static create(name: string, params: string[]): void {
    const { mode, registered } = currentScope();
    const address = params[0];
    if (!address) {
      throw new Error(`${name}.create() was called without an address parameter`);
    }
    const key = `${name}:${address.toLowerCase()}`;
    // Replays rerun the mapping from the top, so registration is deduped
    // rather than repeated.
    if (mode !== "register" || registered.has(key)) return;
    registered.add(key);
    registerHook?.(name, address);
  }
  static createWithContext(name: string, params: string[], context: DataSourceContext): void {
    // The created data source would have to carry the context to every event it
    // ever sees, and there is nowhere to keep it — `dataSource.context()` in the
    // template's handlers would quietly come back empty.
    if (context.entries.length > 0) {
      throw unsupported(
        `${name}.createWithContext() with a non-empty context`,
        "a mapping handler",
      );
    }
    DataSourceTemplate.create(name, params);
  }
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
    return Address.fromString(currentScope().dataSource.address);
  },
  network(): string {
    return currentScope().dataSource.network;
  },
  context(): DataSourceContext {
    const context = new DataSourceContext();
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

export enum LogLevel {
  CRITICAL = 0,
  ERROR = 1,
  WARNING = 2,
  INFO = 3,
  DEBUG = 4,
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
    currentScope().context.log?.debug(interpolate(message, args));
  },
  info(message: string, args: string[] = []) {
    currentScope().context.log?.info(interpolate(message, args));
  },
  warning(message: string, args: string[] = []) {
    currentScope().context.log?.warn(interpolate(message, args));
  },
  error(message: string, args: string[] = []) {
    currentScope().context.log?.error(interpolate(message, args));
  },
  // graph-node halts the subgraph on critical.
  critical(message: string, args: string[] = []): never {
    throw new Error(interpolate(message, args));
  },
};

export const log = strictNamespace("log", logImpl);

const cryptoImpl = {
  keccak256(input: ByteArray): ByteArray {
    return ByteArray.fromHexString(viemKeccak256(input as Uint8Array));
  },
};

export const crypto = strictNamespace("crypto", cryptoImpl);

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
  toI64(value: JSONValue): bigint {
    return value.toI64();
  },
  toU64(value: JSONValue): bigint {
    return value.toI64();
  },
  toF64(value: JSONValue): number {
    return value.toF64();
  },
  toBigInt(value: JSONValue): BigInt_ {
    return value.toBigInt();
  },
  try_fromString(input: string) {
    try {
      return { isOk: true, isError: false, value: jsonImpl.fromString(input), error: null };
    } catch {
      return { isOk: false, isError: true, value: null, error: true };
    }
  },
  try_fromBytes(bytes: Bytes) {
    try {
      return { isOk: true, isError: false, value: jsonImpl.fromBytes(bytes), error: null };
    } catch {
      return { isOk: false, isError: true, value: null, error: true };
    }
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

function decodeBase64(encoded: string | null): Bytes | null {
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

/** graph-ts hands a block handler an `ethereum.Block`; only `number` is free. */
export function makeBlockHandlerBlock(blockNumber: number, location: string): EthereumBlock {
  const block = new EthereumBlock(BigInt_.fromI32(blockNumber), () =>
    BigInt_.fromString(hostsOrThrow().blockTimestamp(blockNumber)),
  );
  // A post-hoc fetch of the rest can't be made reorg-consistent, so the other
  // fields are refused rather than guessed.
  for (const field of [
    "hash",
    "parentHash",
    "unclesHash",
    "author",
    "stateRoot",
    "transactionsRoot",
    "receiptsRoot",
    "gasUsed",
    "gasLimit",
    "difficulty",
    "totalDifficulty",
    "size",
    "baseFeePerGas",
  ]) {
    refusedGetter(block, field, `block.${field} in a block handler`, location);
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
  return strictNamespace(name, Object.assign(cast, { MIN_VALUE: min, MAX_VALUE: max }));
}

function bigIntegerNamespace(name: string, signed: boolean) {
  const min = signed ? -(2n ** 63n) : 0n;
  const max = signed ? 2n ** 63n - 1n : 2n ** 64n - 1n;
  const cast = (value: unknown) =>
    typeof value === "bigint" ? value : BigInt(Math.trunc(Number(value)) || 0);
  return strictNamespace(name, Object.assign(cast, { MIN_VALUE: min, MAX_VALUE: max }));
}

function floatNamespace(name: string, single: boolean) {
  const cast = (value: unknown) => (single ? Math.fround(Number(value)) : Number(value));
  return strictNamespace(
    name,
    Object.assign(cast, {
      MIN_VALUE: single ? 1.4012984643248171e-45 : Number.MIN_VALUE,
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

export const assemblyScriptPrimitives: Record<string, unknown> = {
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
