import './eager-offset';
import { ByteArray, Bytes } from './collections';
/** Host interface for BigInt arithmetic */
export declare namespace bigInt {
    function plus(x: BigInt, y: BigInt): BigInt;
    function minus(x: BigInt, y: BigInt): BigInt;
    function times(x: BigInt, y: BigInt): BigInt;
    function dividedBy(x: BigInt, y: BigInt): BigInt;
    function dividedByDecimal(x: BigInt, y: BigDecimal): BigDecimal;
    function mod(x: BigInt, y: BigInt): BigInt;
    function pow(x: BigInt, exp: number): BigInt;
    function fromString(s: string): BigInt;
    function bitOr(x: BigInt, y: BigInt): BigInt;
    function bitAnd(x: BigInt, y: BigInt): BigInt;
    function leftShift(x: BigInt, bits: number): BigInt;
    function rightShift(x: BigInt, bits: number): BigInt;
}
/** Host interface for BigDecimal */
export declare namespace bigDecimal {
    function plus(x: BigDecimal, y: BigDecimal): BigDecimal;
    function minus(x: BigDecimal, y: BigDecimal): BigDecimal;
    function times(x: BigDecimal, y: BigDecimal): BigDecimal;
    function dividedBy(x: BigDecimal, y: BigDecimal): BigDecimal;
    function equals(x: BigDecimal, y: BigDecimal): boolean;
    function toString(bigDecimal: BigDecimal): string;
    function fromString(s: string): BigDecimal;
}
export type Int8 = bigint;
export type Timestamp = bigint;
/** An Ethereum address (20 bytes). */
export declare class Address extends Bytes {
    static fromString(s: string): Address;
    /** Convert `Bytes` that must be exactly 20 bytes long to an address.
     * Passing in a value with fewer or more bytes will result in an error */
    static fromBytes(b: Bytes): Address;
    static zero(): Address;
}
/** An arbitrary size integer represented as an array of bytes. */
export declare class BigInt extends Uint8Array {
    static fromI32(x: number): BigInt;
    static fromU32(x: number): BigInt;
    static fromI64(x: bigint): BigInt;
    static fromU64(x: bigint): BigInt;
    static zero(): BigInt;
    /**
     * `bytes` assumed to be little-endian. If your input is big-endian, call `.reverse()` first.
     */
    static fromSignedBytes(bytes: Bytes): BigInt;
    static fromByteArray(byteArray: ByteArray): BigInt;
    /**
     * `bytes` assumed to be little-endian. If your input is big-endian, call `.reverse()` first.
     */
    static fromUnsignedBytes(bytes: ByteArray): BigInt;
    toHex(): string;
    toHexString(): string;
    toString(): string;
    static fromString(s: string): BigInt;
    toI32(): number;
    toU32(): number;
    toI64(): bigint;
    toU64(): bigint;
    toBigDecimal(): BigDecimal;
    isZero(): boolean;
    isI32(): boolean;
    abs(): BigInt;
    sqrt(): BigInt;
    plus(other: BigInt): BigInt;
    minus(other: BigInt): BigInt;
    times(other: BigInt): BigInt;
    div(other: BigInt): BigInt;
    divDecimal(other: BigDecimal): BigDecimal;
    mod(other: BigInt): BigInt;
    equals(other: BigInt): boolean;
    notEqual(other: BigInt): boolean;
    lt(other: BigInt): boolean;
    gt(other: BigInt): boolean;
    le(other: BigInt): boolean;
    ge(other: BigInt): boolean;
    neg(): BigInt;
    bitOr(other: BigInt): BigInt;
    bitAnd(other: BigInt): BigInt;
    leftShift(bits: number): BigInt;
    rightShift(bits: number): BigInt;
    pow(exp: number): BigInt;
    /**
     * Returns −1 if a < b, 1 if a > b, and 0 if A == B
     */
    static compare(a: BigInt, b: BigInt): number;
}
export declare class BigDecimal {
    digits: BigInt;
    exp: BigInt;
    constructor(bigInt: BigInt);
    static fromString(s: string): BigDecimal;
    static zero(): BigDecimal;
    toString(): string;
    truncate(decimals: number): BigDecimal;
    plus(other: BigDecimal): BigDecimal;
    minus(other: BigDecimal): BigDecimal;
    times(other: BigDecimal): BigDecimal;
    div(other: BigDecimal): BigDecimal;
    equals(other: BigDecimal): boolean;
    notEqual(other: BigDecimal): boolean;
    lt(other: BigDecimal): boolean;
    gt(other: BigDecimal): boolean;
    le(other: BigDecimal): boolean;
    ge(other: BigDecimal): boolean;
    neg(): BigDecimal;
    /**
     * Returns −1 if a < b, 1 if a > b, and 0 if A == B
     */
    static compare(a: BigDecimal, b: BigDecimal): number;
}
/** A type representing Starknet's field element type. */
export declare class Felt extends Bytes {
    /**
     * Modifies and transforms the object IN-PLACE into `BigInt`.
     */
    intoBigInt(): BigInt;
}
