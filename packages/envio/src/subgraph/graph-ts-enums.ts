/**
 * The type checker relates enums from separate declarations only when they
 * share a name, so these carry graph-ts' own names — the conformance check
 * then sees them as the enums a mapping codes against.
 */

/** `ethereum.ValueKind` */
export enum ValueKind {
  ADDRESS = 0,
  FIXED_BYTES = 1,
  BYTES = 2,
  INT = 3,
  UINT = 4,
  BOOL = 5,
  STRING = 6,
  FIXED_ARRAY = 7,
  ARRAY = 8,
  TUPLE = 9,
}

/** `log.Level` */
export enum Level {
  CRITICAL = 0,
  ERROR = 1,
  WARNING = 2,
  INFO = 3,
  DEBUG = 4,
}
