import BigNumber from 'bignumber.js';

export class BigDecimal {
  private value: BigNumber;

  constructor(value: BigNumber) {
    this.value = value;
  }

  static fromBigInt(value: BigInt): BigDecimal {
    return new BigDecimal(new BigNumber(value as any));
  }

  static fromFloat(value: number): BigDecimal {
    return new BigDecimal(new BigNumber(value));
  }

  static fromInt(value: number): BigDecimal {
    return new BigDecimal(new BigNumber(value));
  }

  static fromStringUnsafe(value: string): BigDecimal {
    return new BigDecimal(new BigNumber(value));
  }

  static fromString(value: string): BigDecimal | undefined {
    try {
      return new BigDecimal(new BigNumber(value));
    } catch {
      return undefined;
    }
  }

  toString(): string {
    return this.value.toString();
  }

  toFixed(value: number): string {
    return this.value.toFixed(value);
  }

  toInt(): number | undefined {
    const intValue = parseInt(this.value.toString(), 10);
    return isNaN(intValue) ? undefined : intValue;
  }

  plus(other: BigDecimal): BigDecimal {
    return new BigDecimal(this.value.plus(other.value));
  }

  minus(other: BigDecimal): BigDecimal {
    return new BigDecimal(this.value.minus(other.value));
  }

  times(other: BigDecimal): BigDecimal {
    return new BigDecimal(this.value.multipliedBy(other.value));
  }

  div(other: BigDecimal): BigDecimal {
    return new BigDecimal(this.value.dividedBy(other.value));
  }

  equals(other: BigDecimal): boolean {
    return this.value.isEqualTo(other.value);
  }

  notEquals(other: BigDecimal): boolean {
    return !this.value.isEqualTo(other.value);
  }

  gt(other: BigDecimal): boolean {
    return this.value.isGreaterThan(other.value);
  }

  gte(other: BigDecimal): boolean {
    return this.value.isGreaterThanOrEqualTo(other.value);
  }

  lt(other: BigDecimal): boolean {
    return this.value.isLessThan(other.value);
  }

  lte(other: BigDecimal): boolean {
    return this.value.isLessThanOrEqualTo(other.value);
  }
}

export default BigDecimal;
