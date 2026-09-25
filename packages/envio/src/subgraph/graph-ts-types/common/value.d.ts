import './eager-offset';
import { Bytes, TypedMap } from './collections';
import { Address, BigDecimal, BigInt } from './numbers';
/**
 * Enum for supported value types.
 */
export declare enum ValueKind {
    STRING = 0,
    INT = 1,
    BIGDECIMAL = 2,
    BOOL = 3,
    ARRAY = 4,
    NULL = 5,
    BYTES = 6,
    BIGINT = 7,
    INT8 = 8,
    TIMESTAMP = 9
}
/**
 * Pointer type for Value data.
 *
 * Big enough to fit any pointer or native `this.data`.
 */
export type ValuePayload = bigint;
/**
 * A dynamically typed value.
 */
export declare class Value {
    kind: ValueKind;
    data: ValuePayload;
    constructor(kind: ValueKind, data: ValuePayload);
    toAddress(): Address;
    toBoolean(): boolean;
    toBytes(): Bytes;
    toI32(): number;
    toI64(): bigint;
    toTimestamp(): bigint;
    toString(): string;
    toBigInt(): BigInt;
    toBigDecimal(): BigDecimal;
    toArray(): Array<Value>;
    toMatrix(): Array<Array<Value>>;
    toBooleanArray(): Array<boolean>;
    toBytesArray(): Array<Bytes>;
    toStringArray(): Array<string>;
    toI32Array(): Array<number>;
    toI64Array(): Array<bigint>;
    toTimestampArray(): Array<bigint>;
    toBigIntArray(): Array<BigInt>;
    toBigDecimalArray(): Array<BigDecimal>;
    toBooleanMatrix(): Array<Array<boolean>>;
    toBytesMatrix(): Array<Array<Bytes>>;
    toAddressMatrix(): Array<Array<Address>>;
    toStringMatrix(): Array<Array<string>>;
    toI32Matrix(): Array<Array<number>>;
    toI64Matrix(): Array<Array<bigint>>;
    toBigIntMatrix(): Array<Array<BigInt>>;
    /** Return a string that indicates the kind of value `this` contains for
     * logging and error messages */
    displayKind(): string;
    /** Return a string representation of the value of `this` for logging and
     * error messages */
    displayData(): string;
    static fromBooleanArray(input: Array<boolean>): Value;
    static fromBytesArray(input: Array<Bytes>): Value;
    static fromI32Array(input: Array<number>): Value;
    static fromI64Array(input: Array<bigint>): Value;
    static fromBigIntArray(input: Array<BigInt>): Value;
    static fromBigDecimalArray(input: Array<BigDecimal>): Value;
    static fromStringArray(input: Array<string>): Value;
    static fromAddressArray(input: Array<Address>): Value;
    static fromArray(input: Array<Value>): Value;
    static fromBigInt(n: BigInt): Value;
    static fromBoolean(b: boolean): Value;
    static fromBytes(bytes: Bytes): Value;
    static fromNull(): Value;
    static fromI32(n: number): Value;
    static fromI64(n: bigint): Value;
    static fromTimestamp(n: bigint): Value;
    static fromString(s: string): Value;
    static fromAddress(s: Address): Value;
    static fromBigDecimal(n: BigDecimal): Value;
    static fromMatrix(values: Array<Array<Value>>): Value;
    static fromBooleanMatrix(values: Array<Array<boolean>>): Value;
    static fromBytesMatrix(values: Array<Array<Bytes>>): Value;
    static fromAddressMatrix(values: Array<Array<Address>>): Value;
    static fromStringMatrix(values: Array<Array<string>>): Value;
    static fromI32Matrix(values: Array<Array<number>>): Value;
    static fromI64Matrix(values: Array<Array<bigint>>): Value;
    static fromTimestampMatrix(values: Array<Array<bigint>>): Value;
    static fromBigIntMatrix(values: Array<Array<BigInt>>): Value;
}
/** Type hint for JSON values. */
export declare enum JSONValueKind {
    NULL = 0,
    BOOL = 1,
    NUMBER = 2,
    STRING = 3,
    ARRAY = 4,
    OBJECT = 5
}
/**
 * Pointer type for JSONValue data.
 *
 * Big enough to fit any pointer or native `this.data`.
 */
export type JSONValuePayload = bigint;
export declare class JSONValue {
    kind: JSONValueKind;
    data: JSONValuePayload;
    isNull(): boolean;
    toBool(): boolean;
    toI64(): bigint;
    toU64(): bigint;
    toF64(): number;
    toBigInt(): BigInt;
    toString(): string;
    toArray(): Array<JSONValue>;
    toObject(): TypedMap<string, JSONValue>;
}
