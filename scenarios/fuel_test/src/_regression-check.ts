// Regression guards for the public TypeScript surface of event-level
// `where.block` filters. CodeRabbit caught a class of bug on PR #1131
// where `FuelOnEventWhere` was aliased to `EvmOnEventWhere`, bypassing
// `FuelOnEventWhereFilter` and quietly typing Fuel users against EVM's
// `block.number` shape. Keep these checks next to a real handler file so
// they run under the project's normal `tsc --noEmit` gate.
import type {
  EvmOnEventWhere,
  EvmOnEventWhereFilter,
  FuelOnEventWhere,
  FuelOnEventWhereFilter,
} from "envio";

// Filter-shape invariant: Fuel's block key is `height`, EVM's is `number`.
// Catches a field rename / swap in `index.d.ts`.
type _FuelBlockKeys = keyof NonNullable<FuelOnEventWhereFilter<{}>["block"]>;
type _EvmBlockKeys = keyof NonNullable<EvmOnEventWhereFilter<{}>["block"]>;
const _fuelHeight: "height" extends _FuelBlockKeys ? true : false = true;
const _fuelNoNumber: "number" extends _FuelBlockKeys ? false : true = true;
const _evmNumber: "number" extends _EvmBlockKeys ? true : false = true;
const _evmNoHeight: "height" extends _EvmBlockKeys ? false : true = true;
void _fuelHeight; void _fuelNoNumber; void _evmNumber; void _evmNoHeight;

// Wrapper-alias guard: the two ecosystems' wrappers must NOT be mutually
// assignable. If `FuelOnEventWhere = EvmOnEventWhere` sneaks back in,
// their component filters collapse to the same structural type and this
// asymmetry check flips to `true`.
type _FuelAssignableToEvm = FuelOnEventWhere<{}, "C"> extends EvmOnEventWhere<{}, "C"> ? true : false;
type _EvmAssignableToFuel = EvmOnEventWhere<{}, "C"> extends FuelOnEventWhere<{}, "C"> ? true : false;
const _fuelNotEvm: _FuelAssignableToEvm = false;
const _evmNotFuel: _EvmAssignableToFuel = false;
void _fuelNotEvm; void _evmNotFuel;

// Inner-range invariant: only `_gte` is public; `_lte` and `_every`
// would be caught by `S.strict` at runtime, but document the TS surface
// too so handler authors see the same constraint at edit time.
// Bidirectional equality check — `[never] extends ["_gte"]` is `true`
// (never is the bottom type), so a one-way check would silently pass if
// `_gte` were accidentally removed. `_ExactlyGte` requires the keyset
// to be exactly `"_gte"`, rejecting both `never` and any wider union.
type _FuelRangeKeys = keyof NonNullable<NonNullable<FuelOnEventWhereFilter<{}>["block"]>["height"]>;
type _EvmRangeKeys = keyof NonNullable<NonNullable<EvmOnEventWhereFilter<{}>["block"]>["number"]>;
type _ExactlyGte<T> = [T] extends ["_gte"] ? (["_gte"] extends [T] ? true : false) : false;
const _fuelGteOnly: _ExactlyGte<_FuelRangeKeys> = true;
const _evmGteOnly: _ExactlyGte<_EvmRangeKeys> = true;
void _fuelGteOnly; void _evmGteOnly;
