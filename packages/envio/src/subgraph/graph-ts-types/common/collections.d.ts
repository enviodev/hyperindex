import { BigDecimal, BigInt } from './numbers';
import { Value } from './value';
/**
 * Byte array
 */
export declare class ByteArray extends Uint8Array {
    /**
     * Returns bytes in little-endian order.
     */
    static fromI32(x: number): ByteArray;
    /**
     * Returns bytes in little-endian order.
     */
    static fromU32(x: number): ByteArray;
    /**
     * Returns bytes in little-endian order.
     */
    static fromI64(x: bigint): ByteArray;
    /**
     * Returns bytes in little-endian order.
     */
    static fromU64(x: bigint): ByteArray;
    static empty(): ByteArray;
    /**
     * Convert the string `hex` which must consist of an even number of
     * hexadecimal digits to a `ByteArray`. The string `hex` can optionally
     * start with '0x'
     */
    static fromHexString(hex: string): ByteArray;
    static fromUTF8(str: string): ByteArray;
    static fromBigInt(bigInt: BigInt): ByteArray;
    toHex(): string;
    toHexString(): string;
    toString(): string;
    toBase58(): string;
    /**
     * Interprets the byte array as a little-endian U32.
     * Throws in case of overflow.
     */
    toU32(): number;
    /**
     * Interprets the byte array as a little-endian I32.
     * Throws in case of overflow.
     */
    toI32(): number;
    /** Create a new `ByteArray` that consist of `this` directly followed by
     * the bytes from `other` */
    concat(other: ByteArray): ByteArray;
    /** Create a new `ByteArray` that consists of `this` directly followed by
     * the representation of `other` as bytes */
    concatI32(other: number): ByteArray;
    /**
     * Interprets the byte array as a little-endian I64.
     * Throws in case of overflow.
     */
    toI64(): bigint;
    /**
     * Interprets the byte array as a little-endian U64.
     * Throws in case of overflow.
     */
    toU64(): bigint;
    equals(other: ByteArray): boolean;
    notEqual(other: ByteArray): boolean;
}
/** A dynamically-sized byte array. */
export declare class Bytes extends ByteArray {
    static fromByteArray(byteArray: ByteArray): Bytes;
    static fromUint8Array(uint8Array: Uint8Array): Bytes;
    /**
     * Convert the string `hex` which must consist of an even number of
     * hexadecimal digits to a `ByteArray`. The string `hex` can optionally
     * start with '0x'
     */
    static fromHexString(str: string): Bytes;
    static fromUTF8(str: string): Bytes;
    static fromI32(i: number): Bytes;
    static empty(): Bytes;
    concat(other: Bytes): Bytes;
    concatI32(other: number): Bytes;
}
/**
 * TypedMap entry.
 */
export declare class TypedMapEntry<K, V> {
    key: K;
    value: V;
    constructor(key: K, value: V);
}
/** Typed map */
export declare class TypedMap<K, V> {
    entries: Array<TypedMapEntry<K, V>>;
    constructor();
    set(key: K, value: V): void;
    getEntry(key: K): TypedMapEntry<K, V> | null;
    mustGetEntry(key: K): TypedMapEntry<K, V>;
    get(key: K): V | null;
    mustGet(key: K): V;
    isSet(key: K): boolean;
}
/**
 * Common representation for entity data, storing entity attributes
 * as `string` keys and the attribute values as dynamically-typed
 * `Value` objects.
 */
export declare class Entity extends TypedMap<string, Value> {
    unset(key: string): void;
    /** Assigns properties from sources to this Entity in right-to-left order */
    merge(sources: Array<Entity>): Entity;
    setString(key: string, value: string): void;
    setI32(key: string, value: number): void;
    setBigInt(key: string, value: BigInt): void;
    setBytes(key: string, value: Bytes): void;
    setBoolean(key: string, value: boolean): void;
    setBigDecimal(key: string, value: BigDecimal): void;
    getString(key: string): string;
    getI32(key: string): number;
    getBigInt(key: string): BigInt;
    getBytes(key: string): Bytes;
    getBoolean(key: string): boolean;
    getBigDecimal(key: string): BigDecimal;
}
/**
 * The result of an operation, with a corresponding value and error type.
 */
export declare class Result<V, E> {
    _value: Wrapped<V> | null;
    _error: Wrapped<E> | null;
    get isOk(): boolean;
    get isError(): boolean;
    get value(): V;
    get error(): E;
}
export declare class Wrapped<T> {
    inner: T;
    constructor(inner: T);
}
