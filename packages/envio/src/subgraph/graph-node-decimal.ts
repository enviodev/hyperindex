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

/** Every operation reaches for powers of ten; they're computed once. */
const TENS: bigint[] = [1n];
function ten(power: number): bigint {
  if (power > 4096) return 10n ** BigInt(power);
  while (TENS.length <= power) TENS.push(TENS[TENS.length - 1] * 10n);
  return TENS[power];
}
const abs = (n: bigint) => (n < 0n ? -n : n);
/** The magnitude's bit length, as num-bigint's `bits()`. */
function bits(n: bigint): number {
  if (n === 0n) return 0;
  const hex = abs(n).toString(16);
  return (hex.length - 1) * 4 + (32 - Math.clz32(parseInt(hex[0], 16)));
}

/** `count_decimal_digits`: never corrects its guess upward for a negative. */
function countDigits(n: bigint): number {
  if (n === 0n) return 1;
  // For a positive the crate's guess never overshoots and its loop corrects
  // it to the exact count, which a float's log10 finds with fewer steps.
  const approximate = Number(n);
  if (n > 0n && approximate < 1e300) {
    let digits = Math.max(1, Math.floor(Math.log10(approximate)) + 1);
    while (digits > 1 && n < ten(digits - 1)) digits -= 1;
    while (n >= ten(digits)) digits += 1;
    return digits;
  }
  let digits = Math.floor(bits(n) / LOG2_10);
  let num = ten(digits);
  while (n >= num) {
    num *= 10n;
    digits += 1;
  }
  return digits;
}

/** `get_rounding_term` of a positive: 1 when its leading digit is 5 or more. */
function roundingTerm(n: bigint): bigint {
  if (n === 0n) return 0n;
  return n >= 5n * ten(countDigits(n) - 1) ? 1n : 0n;
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

const ZERO: Decimal = { int: 0n, scale: 0 };
const TEN_TO_THE_8 = 10n ** 8n;

/**
 * graph-node's `BigDecimal::normalized`, applied to every value it makes:
 * `with_prec(34)`, then trailing zeros dropped. A coefficient of 34 digits or
 * fewer comes out of `with_prec` padded with zeros that the second step drops
 * again, so only its own trailing zeros are dropped.
 */
export function normalize(value: Decimal): Decimal {
  if (value.int === 0n) return ZERO;
  let { int, scale } =
    countDigits(value.int) > MAX_SIGNIFICANT_DIGITS ? withPrecision(value, MAX_SIGNIFICANT_DIGITS) : value;
  if (int % 10n !== 0n) return int === value.int ? value : { int, scale };
  while (int % TEN_TO_THE_8 === 0n) {
    int /= TEN_TO_THE_8;
    scale -= 8;
  }
  while (int % 10n === 0n) {
    int /= 10n;
    scale -= 1;
  }
  return { int, scale };
}

/** The sign of `a - b`. */
export function compare(a: Decimal, b: Decimal): number {
  const [x, y] = align(a, b);
  return x < y ? -1 : x > y ? 1 : 0;
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
  const first = num / den;
  if (num % den === 0n) return { int: first, scale };
  // The crate appends one digit at a time until the remainder is zero or the
  // quotient has DIVISION_DIGITS digits, then rounds half up on the next
  // digit. One division of `num * 10 ** extra` gives the same digits: the
  // digit that ends the remainder is never zero, so an early stop shows as
  // the quotient's trailing zeros.
  const extra = Math.max(0, DIVISION_DIGITS - countDigits(first));
  let quotient = (num * ten(extra)) / den;
  const remainder = (num * ten(extra)) % den;
  if (remainder !== 0n) return { int: quotient + (2n * remainder >= den ? 1n : 0n), scale: scale + extra };
  let appended = extra;
  while (appended > 0 && quotient % 10n === 0n) {
    quotient /= 10n;
    appended -= 1;
  }
  return { int: quotient, scale: scale + appended };
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
