import { expect } from 'chai';
// import { BigDecimal } from 'generated';/// For some reason this doesn't work?
import BigDecimal from '../generated/src/bindings/BigDecimal';

describe('BigDecimal', () => {
  it('should create BigDecimal from BigInt', () => {
    const bigDecimal = BigDecimal.fromBigInt(BigInt(123456789));
    expect(bigDecimal.toString()).to.equal('123456789');
  });

  it('should create BigDecimal from float', () => {
    const bigDecimal = BigDecimal.fromFloat(123.456);
    expect(bigDecimal.toString()).to.equal('123.456');
  });

  it('should create BigDecimal from int', () => {
    const bigDecimal = BigDecimal.fromInt(123);
    expect(bigDecimal.toString()).to.equal('123');
  });

  it('should create BigDecimal from string (unsafe)', () => {
    const bigDecimal = BigDecimal.fromStringUnsafe('123.456');
    expect(bigDecimal.toString()).to.equal('123.456');
  });

  it('should create BigDecimal from string safely', () => {
    const bigDecimal = BigDecimal.fromString('123.456');
    expect(bigDecimal?.toString()).to.equal('123.456');
  });

  it('should convert BigDecimal to string', () => {
    const bigDecimal = BigDecimal.fromFloat(123.456);
    expect(bigDecimal.toString()).to.equal('123.456');
  });

  it('should convert BigDecimal to fixed string', () => {
    const bigDecimal = BigDecimal.fromFloat(123.456);
    expect(bigDecimal.toFixed(2)).to.equal('123.46'); // Rounding may vary
  });

  it('should convert BigDecimal to int', () => {
    const bigDecimal = BigDecimal.fromFloat(123.456);
    expect(bigDecimal.toInt()).to.equal(123);
  });

  it('should perform addition', () => {
    const a = BigDecimal.fromFloat(10);
    const b = BigDecimal.fromFloat(20);
    const result = a.plus(b);
    expect(result.toString()).to.equal('30');
  });

  it('should perform subtraction', () => {
    const a = BigDecimal.fromFloat(20);
    const b = BigDecimal.fromFloat(10);
    const result = a.minus(b);
    expect(result.toString()).to.equal('10');
  });

  it('should perform multiplication', () => {
    const a = BigDecimal.fromFloat(2);
    const b = BigDecimal.fromFloat(3);
    const result = a.times(b);
    expect(result.toString()).to.equal('6');
  });

  it('should perform division', () => {
    const a = BigDecimal.fromFloat(6);
    const b = BigDecimal.fromFloat(2);
    const result = a.div(b);
    expect(result.toString()).to.equal('3');
  });

  it('should check equality', () => {
    const a = BigDecimal.fromFloat(10);
    const b = BigDecimal.fromFloat(10);
    expect(a.equals(b)).to.be.true;
  });

  it('should check inequality', () => {
    const a = BigDecimal.fromFloat(10);
    const b = BigDecimal.fromFloat(20);
    expect(a.notEquals(b)).to.be.true;
  });

  it('should check greater than', () => {
    const a = BigDecimal.fromFloat(20);
    const b = BigDecimal.fromFloat(10);
    expect(a.gt(b)).to.be.true;
  });

  it('should check greater than or equal', () => {
    const a = BigDecimal.fromFloat(20);
    const b = BigDecimal.fromFloat(10);
    expect(a.gte(b)).to.be.true;
    expect(a.gte(a)).to.be.true;
  });

  it('should check less than', () => {
    const a = BigDecimal.fromFloat(10);
    const b = BigDecimal.fromFloat(20);
    expect(a.lt(b)).to.be.true;
  });

  it('should check less than or equal', () => {
    const a = BigDecimal.fromFloat(10);
    const b = BigDecimal.fromFloat(20);
    expect(a.lte(b)).to.be.true;
    expect(a.lte(a)).to.be.true;
  });
});
