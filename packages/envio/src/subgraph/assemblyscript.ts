/**
 * The runtime half of `packages/cli/src/subgraph/assemblyscript.rs`, which
 * rewrites every `/` in a mapping into a call to `DIVIDE_HELPER`, every
 * `changetype<Foo>(x)` into one to `RETAG_HELPER`, and exports each handler's
 * event class as `EVENT_CLASSES_EXPORT`. The names are shared with that file.
 */

export const DIVIDE_HELPER = "__envio_idiv";
export const RETAG_HELPER = "__envio_retag";
export const EVENT_CLASSES_EXPORT = "__envio_event_classes";

/**
 * AssemblyScript divides two integers as integers; this truncates only when
 * both operands really are integers and otherwise divides as before — an `f64`
 * divides as a float in AssemblyScript too.
 */
export function integerDivision(a: unknown, b: unknown): unknown {
  const left = typeof a === "object" && a !== null ? (a as any).valueOf() : a;
  const right = typeof b === "object" && b !== null ? (b as any).valueOf() : b;

  const integral = (v: unknown) =>
    typeof v === "bigint" || (typeof v === "number" && Number.isInteger(v));
  if (integral(left) && integral(right)) {
    // Only i64 / i64 stays 64-bit; anything narrower is an i32 in AssemblyScript
    // and must come back as a number, or the bigint spreads through every
    // arithmetic that follows.
    if (typeof left === "bigint" && typeof right === "bigint") {
      return left / right;
    }
    return Math.trunc(Number(left) / Number(right));
  }
  return (left as number) / (right as number);
}
