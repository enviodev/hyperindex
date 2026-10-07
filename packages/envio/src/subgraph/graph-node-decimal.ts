/**
 * graph-node's `BigDecimal` arithmetic, digit for digit.
 *
 * graph-node pins `bigdecimal` 0.1.2 for determinism and normalizes every value
 * it makes to 34 significant digits through that crate's `with_prec`. The
 * crate's rounding has quirks a subgraph's stored values inherit — positives
 * round half up, negatives truncate, and its digit count for a negative
 * coefficient undercounts, so those keep a digit more — so it is reproduced
 * here on the same integer-and-scale representation rather than approximated
 * with a general decimal library.
 */

/** `int * 10 ** -scale`, as the crate holds a value. */
export type Decimal = { int: bigint; scale: number };

const MAX_SIGNIFICANT_DIGITS = 34;
const DIVISION_DIGITS = 100;
const LOG2_10 = 3.3219280949;

const ten = (power: number) => 10n ** BigInt(power);
const abs = (n: bigint) => (n < 0n ? -n : n);
const bits = (n: bigint) => (n === 0n ? 0 : abs(n).toString(2).length);

/** `count_decimal_digits`: never corrects its guess upward for a negative. */
function countDigits(n: bigint): number {
  if (n === 0n) return 1;
  let digits = Math.floor(bits(n) / LOG2_10);
  let num = ten(digits);
  while (n >= num) {
    num *= 10n;
    digits += 1;
  }
  return digits;
}

/** `get_rounding_term`: 1 when the leading digit of `n` is 5 or more. */
function roundingTerm(n: bigint): bigint {
  if (n === 0n) return 0n;
  let bound = ten(Math.floor(bits(n) / LOG2_10));
  for (;;) {
    if (n < bound) return 1n;
    bound *= 5n;
    if (n < bound) return 0n;
    bound *= 2n;
  }
}

function withPrecision({ int, scale }: Decimal, precision: number): Decimal {
  const digits = countDigits(int);
  if (digits > precision) {
    const diff = digits - precision;
    const p = ten(diff);
    let quotient = int / p;
    const remainder = int % p;
    if (p < 10n * remainder) quotient += roundingTerm(remainder);
    return { int: quotient, scale: scale - diff };
  }
  if (digits < precision) {
    const diff = precision - digits;
    return { int: int * ten(diff), scale: scale + diff };
  }
  return { int, scale };
}

/** graph-node's `BigDecimal::normalized`, applied to every value it makes. */
export function normalize(value: Decimal): Decimal {
  if (value.int === 0n) return { int: 0n, scale: 0 };
  let { int, scale } = withPrecision(value, MAX_SIGNIFICANT_DIGITS);
  while (int % 10n === 0n) {
    int /= 10n;
    scale -= 1;
  }
  return { int, scale };
}

function align(a: Decimal, b: Decimal): [bigint, bigint, number] {
  const scale = Math.max(a.scale, b.scale);
  return [a.int * ten(scale - a.scale), b.int * ten(scale - b.scale), scale];
}

export function add(a: Decimal, b: Decimal): Decimal {
  const [x, y, scale] = align(a, b);
  return normalize({ int: x + y, scale });
}

export function subtract(a: Decimal, b: Decimal): Decimal {
  const [x, y, scale] = align(a, b);
  return normalize({ int: x - y, scale });
}

export function multiply(a: Decimal, b: Decimal): Decimal {
  return normalize({ int: a.int * b.int, scale: a.scale + b.scale });
}

/** The crate's long division: `DIVISION_DIGITS` digits, the last rounded half up. */
function longDivision(num: bigint, den: bigint, scale: number): Decimal {
  if (num === 0n) return { int: 0n, scale: 0 };
  if (num < 0n !== den < 0n) {
    const { int, scale: s } = longDivision(abs(num), abs(den), scale);
    return { int: -int, scale: s };
  }
  num = abs(num);
  den = abs(den);
  while (num < den) {
    scale += 1;
    num *= 10n;
  }
  let quotient = num / den;
  let remainder = num % den;
  if (remainder === 0n) return { int: quotient, scale };
  let precision = countDigits(quotient);
  remainder *= 10n;
  while (remainder !== 0n && precision < DIVISION_DIGITS) {
    quotient = quotient * 10n + remainder / den;
    remainder = (remainder % den) * 10n;
    precision += 1;
    scale += 1;
  }
  if (remainder !== 0n) quotient += roundingTerm(remainder / den);
  return { int: quotient, scale };
}

export function divide(a: Decimal, b: Decimal): Decimal {
  if (b.int === 0n) throw new Error("Cannot divide by zero-valued `BigDecimal`!");
  if (a.int === 0n || (b.int === 1n && b.scale === 0)) return normalize(a);
  const scale = a.scale - b.scale;
  if (a.int === b.int) return normalize({ int: 1n, scale });
  return normalize(longDivision(a.int, b.int, scale));
}

/** The crate's `from_str`: digits, a point and an exponent, all exact. */
export function parse(text: string): Decimal {
  const match = /^([+-]?)(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$/.exec(text.trim());
  if (!match || (match[2] === "" && (match[3] ?? "") === "")) {
    throw new Error(`Invalid BigDecimal: ${text}`);
  }
  const [, sign, lead, trail = "", exponent = "0"] = match;
  const int = BigInt(`${sign === "-" ? "-" : ""}${lead}${trail}` || "0");
  return normalize({ int, scale: trail.length - Number(exponent) });
}

export function fromInteger(value: bigint): Decimal {
  return normalize({ int: value, scale: 0 });
}

/** The plain decimal the crate prints, which is what `toString` returns. */
export function format({ int, scale }: Decimal): string {
  if (scale <= 0) return (int * ten(-scale)).toString();
  const negative = int < 0n;
  const digits = abs(int).toString().padStart(scale + 1, "0");
  const point = digits.length - scale;
  return `${negative ? "-" : ""}${digits.slice(0, point)}.${digits.slice(point)}`;
}
