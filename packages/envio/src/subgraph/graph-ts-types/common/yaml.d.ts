import './eager-offset';
import { Bytes, Result, TypedMap } from './collections';
import { BigInt } from './numbers';
/**
 * Host YAML interface.
 */
export declare namespace yaml {
    /**
     * Parses a YAML document from UTF-8 encoded bytes.
     * Aborts mapping execution if the bytes cannot be parsed.
     */
    function fromBytes(data: Bytes): YAMLValue;
    /**
     * Parses a YAML document from UTF-8 encoded bytes.
     * Returns `Result.error == true` if the bytes cannot be parsed.
     */
    function try_fromBytes(data: Bytes): Result<YAMLValue, boolean>;
}
export declare namespace yaml {
    /**
     * Parses a YAML document from a UTF-8 encoded string.
     * Aborts mapping execution if the string cannot be parsed.
     */
    function fromString(data: string): YAMLValue;
    /**
     * Parses a YAML document from a UTF-8 encoded string.
     * Returns `Result.error == true` if the string cannot be parsed.
     */
    function try_fromString(data: string): Result<YAMLValue, boolean>;
}
/**
 * All possible YAML value types.
 */
export declare enum YAMLValueKind {
    NULL = 0,
    BOOL = 1,
    NUMBER = 2,
    STRING = 3,
    ARRAY = 4,
    OBJECT = 5,
    TAGGED = 6
}
/**
 * Pointer type for `YAMLValue` data.
 *
 * Big enough to fit any pointer or native `YAMLValue.data`.
 */
export type YAMLValuePayload = bigint;
export declare class YAMLValue {
    kind: YAMLValueKind;
    data: YAMLValuePayload;
    constructor(kind: YAMLValueKind, data: YAMLValuePayload);
    static newNull(): YAMLValue;
    static newBool(data: boolean): YAMLValue;
    static newI64(data: bigint): YAMLValue;
    static newU64(data: bigint): YAMLValue;
    static newF64(data: number): YAMLValue;
    static newBigInt(data: BigInt): YAMLValue;
    static newString(data: string): YAMLValue;
    static newArray(data: Array<YAMLValue>): YAMLValue;
    static newObject(data: TypedMap<YAMLValue, YAMLValue>): YAMLValue;
    static newTagged(tag: string, value: YAMLValue): YAMLValue;
    isNull(): boolean;
    isBool(): boolean;
    isNumber(): boolean;
    isString(): boolean;
    isArray(): boolean;
    isObject(): boolean;
    isTagged(): boolean;
    toBool(): boolean;
    toNumber(): string;
    toI64(): bigint;
    toU64(): bigint;
    toF64(): number;
    toBigInt(): BigInt;
    toString(): string;
    toArray(): Array<YAMLValue>;
    toObject(): TypedMap<YAMLValue, YAMLValue>;
    toTagged(): YAMLTaggedValue;
    static eq(a: YAMLValue, b: YAMLValue): boolean;
    static ne(a: YAMLValue | null, b: YAMLValue | null): boolean;
    get(index: string): YAMLValue;
}
export declare class YAMLTaggedValue {
    tag: string;
    value: YAMLValue;
    constructor(tag: string, value: YAMLValue);
    static eq(a: YAMLTaggedValue, b: YAMLTaggedValue): boolean;
    static ne(a: YAMLTaggedValue | null, b: YAMLTaggedValue | null): boolean;
}
