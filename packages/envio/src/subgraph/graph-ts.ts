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
}

export class Bytes extends ByteArray {
  static fromHexString(hex: string): Bytes {
    return new Bytes(ByteArray.fromHexString(hex));
  }
  static fromUTF8(input: string): Bytes {
    return new Bytes(ByteArray.fromUTF8(input));
  }
  static fromByteArray(bytes: ByteArray): Bytes {
    return new Bytes(bytes);
  }
  static fromI32(value: number): Bytes {
    return new Bytes(ByteArray.fromI32(value));
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

class BigInt_ {
  readonly value: bigint;

  constructor(value: bigint) {
    this.value = value;
  }

  static fromI32(value: number): BigInt_ {
    return new BigInt_(BigInt(Math.trunc(value)));
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
  static fromSignedBytes(bytes: ByteArray): BigInt_ {
    return BigInt_.fromByteArray(bytes);
  }
  static zero(): BigInt_ {
    return new BigInt_(0n);
  }

  valueOf(): bigint {
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
  merge(entities: Entity[]): Entity {
    for (const entity of entities) {
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
const entityTail = new Proxy(Object.create(null), {
  get(_target, prop, receiver) {
    if (typeof prop === "symbol" || PROTOTYPE_PASSTHROUGH.has(prop as string)) {
      return undefined;
    }
    const stored = receiver instanceof Entity ? receiver.get(prop as string) : null;
    if (stored !== null) {
      return valueToNative(stored);
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
  const row: Record<string, unknown> = {};
  for (const entry of entity.entries) {
    row[entry.key] = timestampFields.has(entry.key)
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
  const entity = new Entity();
  for (const [key, value] of Object.entries(row)) {
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
  SmartContract,
  SmartContractCall,
  CallResult,
  Block: EthereumBlock,
  Transaction: EthereumTransaction,
  Event: EthereumEvent,
  Tuple: Array,
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
  static createWithContext(name: string, params: string[], _context: DataSourceContext): void {
    DataSourceTemplate.create(name, params);
  }
}

export class DataSourceContext extends Entity {}

const dataSourceImpl = {
  address(): Address {
    return Address.fromString(currentScope().dataSource.address);
  },
  network(): string {
    return currentScope().dataSource.network;
  },
  context(): DataSourceContext {
    return new DataSourceContext();
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

const logImpl = {
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

// AssemblyScript builtins the generated code leans on.
export function changetype<T>(value: unknown): T {
  return value as T;
}
