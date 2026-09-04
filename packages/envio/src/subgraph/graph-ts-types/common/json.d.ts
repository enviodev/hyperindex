import './eager-offset';
import { Bytes, Result } from './collections';
import { BigInt } from './numbers';
import { JSONValue } from './value';
/** Host JSON interface */
export declare namespace json {
    function fromBytes(data: Bytes): JSONValue;
    function try_fromBytes(data: Bytes): Result<JSONValue, boolean>;
    function toI64(decimal: string): bigint;
    function toU64(decimal: string): bigint;
    function toF64(decimal: string): number;
    function toBigInt(decimal: string): BigInt;
}
export declare namespace json {
    function fromString(data: string): JSONValue;
    function try_fromString(data: string): Result<JSONValue, boolean>;
}
