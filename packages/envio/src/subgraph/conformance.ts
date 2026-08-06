/**
 * The shim, checked against the types a subgraph developer codes against.
 *
 * A subgraph's mappings are type-checked by `asc` against
 * `@graphprotocol/graph-ts`, and then run by this shim. Nothing else makes
 * those two agree, so a gap shows up as green types and a runtime error — the
 * worst feedback loop there is. This file closes it: every export the shim
 * claims to provide has to be assignable to the real one.
 *
 * The declarations come from the real package (see
 * `scripts/generate-graph-ts-types.mjs`). This file is type-checked, never run.
 *
 * A `@ts-expect-error` below is a known gap, and it cleans itself up: closing
 * the gap makes the directive unused, which is itself an error, so the comment
 * has to go with the fix. Adding a new one is a deliberate act.
 */

import type * as GraphTs from "./graph-ts-types/index.js";
import * as Shim from "./graph-ts.ts";

// @ts-expect-error graph-ts' BigInt extends Uint8Array, so it carries the
// TypedArray statics (`of`, `from`, `compare`, BYTES_PER_ELEMENT). The shim
// wraps a JS bigint instead, which no mapping can tell apart — mappings only
// ever construct one through `BigInt.from*`.
const _BigInt: typeof GraphTs.BigInt = Shim.BigInt;

// @ts-expect-error missing `compare`.
const _BigDecimal: typeof GraphTs.BigDecimal = Shim.BigDecimal;

// @ts-expect-error missing `fromUint8Array`, `fromU32`, `fromI64`, `fromU64`.
const _Bytes: typeof GraphTs.Bytes = Shim.Bytes;

// @ts-expect-error missing `fromU32`, `fromI64`, `fromU64`.
const _ByteArray: typeof GraphTs.ByteArray = Shim.ByteArray;

// @ts-expect-error missing `fromUint8Array`, `fromU32`, `fromI64`, `fromU64`.
const _Address: typeof GraphTs.Address = Shim.Address;

const _TypedMap: typeof GraphTs.TypedMap = Shim.TypedMap;

const _TypedMapEntry: typeof GraphTs.TypedMapEntry = Shim.TypedMapEntry;

// @ts-expect-error `merge` returns the shim's Entity.
const _Entity: typeof GraphTs.Entity = Shim.Entity;

// @ts-expect-error missing `fromI64Array`, `fromAddressArray`, `fromMatrix`,
// `fromBooleanMatrix` and 7 more array/matrix constructors.
const _Value: typeof GraphTs.Value = Shim.Value;

const _ValueKind: typeof GraphTs.ValueKind = Shim.ValueKind;

// @ts-expect-error `store.get` returns the shim's Entity.
const _store: typeof GraphTs.store = Shim.store;

// @ts-expect-error missing `call`, `ValueKind`, `TransactionReceipt`, `Log`
// and 2 more. `TransactionReceipt`/`Log` back `event.receipt.logs`, which the
// runtime refuses on access.
const _ethereum: typeof GraphTs.ethereum = Shim.ethereum;

// @ts-expect-error missing `stringParam`.
const _dataSource: typeof GraphTs.dataSource = Shim.dataSource;

// @ts-expect-error `createWithContext` takes the shim's DataSourceContext.
const _DataSourceTemplate: typeof GraphTs.DataSourceTemplate = Shim.DataSourceTemplate;

// @ts-expect-error `merge` returns the shim's Entity (inherited).
const _DataSourceContext: typeof GraphTs.DataSourceContext = Shim.DataSourceContext;

// @ts-expect-error missing `log` and `Level`.
const _log: typeof GraphTs.log = Shim.log;

// @ts-expect-error `keccak256` takes the shim's ByteArray.
const _crypto: typeof GraphTs.crypto = Shim.crypto;

// @ts-expect-error missing `toI64`, `toU64`, `toF64`, `toBigInt`,
// `try_fromString`.
const _json: typeof GraphTs.json = Shim.json;

// @ts-expect-error the shim's JSONValue carries its own TypedMap.
const _JSONValue: typeof GraphTs.JSONValue = Shim.JSONValue;

const _JSONValueKind: typeof GraphTs.JSONValueKind = Shim.JSONValueKind;

// @ts-expect-error missing `mapJSON`.
const _ipfs: typeof GraphTs.ipfs = Shim.ipfs;

const _ens: typeof GraphTs.ens = Shim.ens;

export type {};
void [
  _BigInt,
  _BigDecimal,
  _Bytes,
  _ByteArray,
  _Address,
  _TypedMap,
  _TypedMapEntry,
  _Entity,
  _Value,
  _ValueKind,
  _store,
  _ethereum,
  _dataSource,
  _DataSourceTemplate,
  _DataSourceContext,
  _log,
  _crypto,
  _json,
  _JSONValue,
  _JSONValueKind,
  _ipfs,
  _ens,
];
