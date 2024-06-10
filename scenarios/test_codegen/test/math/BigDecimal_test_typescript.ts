import { expect } from 'chai';
import { BigDecimal } from 'generated';

describe('BigDecimal', () => {
  it('should create BigDecimal from BigInt', () => {
    const bigDecimal = new BigDecimal(BigInt(123456789));
    expect(bigDecimal.toString()).to.equal('123456789');
  });

  it('should create BigDecimal from float', () => {
    const bigDecimal = new BigDecimal(123.456);
    expect(bigDecimal.toString()).to.equal('123.456');
  });

  it('should create BigDecimal from int', () => {
    const bigDecimal = new BigDecimal(123);
    expect(bigDecimal.toString()).to.equal('123');
  });

  it('should create BigDecimal from string (unsafe)', () => {
    const bigDecimal = new BigDecimal('123.456');
    expect(bigDecimal.toString()).to.equal('123.456');
  });

  it('should convert BigDecimal to string', () => {
    const bigDecimal = new BigDecimal(123.456);
    expect(bigDecimal.toString()).to.equal('123.456');
  });

  it('should convert BigDecimal to fixed string', () => {
    const bigDecimal = new BigDecimal(123.456);
    expect(bigDecimal.toFixed(2)).to.equal('123.46'); // Rounding may vary
  });

  it('should convert BigDecimal to int', () => {
    const bigDecimal = new BigDecimal(123.456);
    expect(bigDecimal.toFixed(0)).to.equal("123");
  });

  it('should perform addition', () => {
    const a = new BigDecimal(10);
    const b = new BigDecimal(20);
    const result = a.plus(b);
    expect(result.toString()).to.equal('30');
  });

  it('should perform subtraction', () => {
    const a = new BigDecimal(20);
    const b = new BigDecimal(10);
    const result = a.minus(b);
    expect(result.toString()).to.equal('10');
  });

  it('should perform multiplication', () => {
    const a = new BigDecimal(2);
    const b = new BigDecimal(3);
    const result = a.times(b);
    expect(result.toString()).to.equal('6');
  });

  it('should perform division', () => {
    const a = new BigDecimal(6);
    const b = new BigDecimal(2);
    const result = a.div(b);
    expect(result.toString()).to.equal('3');
  });

  it('should check equality', () => {
    const a = new BigDecimal(10);
    const b = new BigDecimal(10);
    expect(a.isEqualTo(b)).to.be.true;
  });

  it('should check greater than', () => {
    const a = new BigDecimal(20);
    const b = new BigDecimal(10);
    expect(a.gt(b)).to.be.true;
  });

  it('should check greater than or equal', () => {
    const a = new BigDecimal(20);
    const b = new BigDecimal(10);
    expect(a.gte(b)).to.be.true;
    expect(a.gte(a)).to.be.true;
  });

  it('should check less than', () => {
    const a = new BigDecimal(10);
    const b = new BigDecimal(20);
    expect(a.lt(b)).to.be.true;
  });

  it('should check less than or equal', () => {
    const a = new BigDecimal(10);
    const b = new BigDecimal(20);
    expect(a.lte(b)).to.be.true;
    expect(a.lte(a)).to.be.true;
  });
});
