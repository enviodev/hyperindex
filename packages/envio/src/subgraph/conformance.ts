/**
 * The shim, checked against the types a subgraph developer codes against.
 *
 * A subgraph's mappings are type-checked by `asc` against
 * `@graphprotocol/graph-ts`, and then run by this shim. Nothing else makes the
 * two agree, so a gap shows up as green types and a runtime error — the worst
 * feedback loop there is. This file closes it.
 *
 * The declarations come from the real package (see
 * `scripts/generate-graph-ts-types.mjs`). Every export is walked, and within
 * each class and namespace every static and every instance member, so a gap is
 * named down to the member — `ethereum.Value.fromAddress` — rather than hidden
 * behind a suppression covering a whole namespace. This file is type-checked,
 * never run.
 */

import type * as GraphTs from "./graph-ts-types/index.js";
import type * as Shim from "./graph-ts.ts";

/** A class's statics: a mapped type drops the construct signature. */
type Statics<T> = { [K in keyof T as K extends "prototype" ? never : K]: T[K] };

type Agrees<Real, Ours, Path extends string> = [Ours] extends [Real] ? never : Path;

/**
 * Deep enough to reach `ethereum.Value.fromAddress`, and no deeper: a member
 * past that is compared whole, which still catches any disagreement inside it.
 */
type Member<Real, Ours, Path extends string, Depth extends unknown[]> = Depth["length"] extends 2
  ? Agrees<Real, Ours, Path>
  : // `any` would take every branch below at once.
    0 extends 1 & Real
    ? Agrees<Real, Ours, Path>
    : // Bracketed so a union — an enum, `boolean` — is compared whole.
      [Real] extends [(...args: any) => any]
    ? Agrees<Real, Ours, Path>
    : // A class, even one whose constructor is protected.
      [Real] extends [{ prototype: infer RealInstance }]
      ? [Ours] extends [{ prototype: infer OursInstance }]
        ?
            | Gaps<Statics<Real>, Statics<Ours>, `${Path}.`, [...Depth, unknown]>
            | Gaps<RealInstance, OursInstance, `${Path}#`, [...Depth, unknown]>
        : Path
      : [Real] extends [object]
        ? Gaps<Real, Ours, `${Path}.`, [...Depth, unknown]>
        : Agrees<Real, Ours, Path>;

/** Where `Ours` lacks or disagrees with `Real`, by path. */
type Gaps<Real, Ours, Path extends string, Depth extends unknown[] = []> = {
  [K in keyof Real & string]-?: K extends keyof Ours
    ? Member<Real[K], Ours[K], `${Path}${K}`, Depth>
    : `${Path}${K}`;
}[keyof Real & string];

type Found = Gaps<typeof GraphTs, typeof Shim, "">;

/** Every gap the shim knows it has, and why. */
type KnownGap =
  // Chains envio doesn't index in subgraph mode.
  | "cosmos"
  | "near"
  | "starknet"
  | "Felt"
  | "arweave.Block"
  | "arweave.ProofOfAccess"
  | "arweave.Tag"
  | "arweave.Transaction"
  | "arweave.TransactionWithBlockPtr"
  // Refused at runtime: a YAML parser isn't shipped with the shim.
  | `yaml.${string}`
  | `YAMLValue${string}`
  | `YAMLTaggedValue${string}`
  // graph-ts declares `CallResult._value` private, which no other declaration
  // can match; the shim's is structurally the same.
  | "ethereum.CallResult.fromValue"
  | "ethereum.SmartContract#tryCall";

/** A known gap no longer found, whose entry should go. */
type Closed<Gap> = Gap extends unknown ? ([Extract<Found, Gap>] extends [never] ? Gap : never) : never;

// Keyed so a failure lists each path as a missing property.
export const unlisted: Record<Exclude<Found, KnownGap>, "a gap KnownGap doesn't list"> = {};
export const closed: Record<Closed<KnownGap>, "a KnownGap entry that no longer applies"> = {};
