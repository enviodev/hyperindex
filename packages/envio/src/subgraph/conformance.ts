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

// @ts-expect-error graph-ts' BigInt extends Uint8Array and is constructed
// from a byte length; this one is constructed from the value it holds. No
// mapping calls `new BigInt(...)` — they go through `BigInt.from*` — and
// every other member matches. The five below are the same difference,
// reached through a BigInt in their own signatures.
const _BigInt: typeof GraphTs.BigInt = Shim.BigInt;

// @ts-expect-error constructor takes a BigInt (see above).
const _BigDecimal: typeof GraphTs.BigDecimal = Shim.BigDecimal;

const _Bytes: typeof GraphTs.Bytes = Shim.Bytes;

const _ByteArray: typeof GraphTs.ByteArray = Shim.ByteArray;

const _Address: typeof GraphTs.Address = Shim.Address;

const _TypedMap: typeof GraphTs.TypedMap = Shim.TypedMap;

const _TypedMapEntry: typeof GraphTs.TypedMapEntry = Shim.TypedMapEntry;

const _Entity: typeof GraphTs.Entity = Shim.Entity;

const _Value: typeof GraphTs.Value = Shim.Value;

const _ValueKind: typeof GraphTs.ValueKind = Shim.ValueKind;

const _store: typeof GraphTs.store = Shim.store;

// @ts-expect-error `ethereum.Value` carries a BigInt (see above).
const _ethereum: typeof GraphTs.ethereum = Shim.ethereum;

const _dataSource: typeof GraphTs.dataSource = Shim.dataSource;

const _DataSourceTemplate: typeof GraphTs.DataSourceTemplate = Shim.DataSourceTemplate;

const _DataSourceContext: typeof GraphTs.DataSourceContext = Shim.DataSourceContext;

// @ts-expect-error `log` formats a BigInt (see above).
const _log: typeof GraphTs.log = Shim.log;

const _crypto: typeof GraphTs.crypto = Shim.crypto;

const _EthereumUtils: typeof GraphTs.EthereumUtils = Shim.EthereumUtils;

// @ts-expect-error `json.toBigInt` returns a BigInt (see above).
const _json: typeof GraphTs.json = Shim.json;

// @ts-expect-error `JSONValue.toBigInt` returns a BigInt (see above).
const _JSONValue: typeof GraphTs.JSONValue = Shim.JSONValue;

const _JSONValueKind: typeof GraphTs.JSONValueKind = Shim.JSONValueKind;

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
  _EthereumUtils,
  _json,
  _JSONValue,
  _JSONValueKind,
  _ipfs,
  _ens,
];
