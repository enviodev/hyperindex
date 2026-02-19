import { expect } from 'chai';
import { BigDecimal } from 'generated';

describe('BigDecimal', () => {
  it('should create BigDecimal from BigInt', () => {
    const bigDecimal = new BigDecimal(123456789123456n as any); // The upstream types don't accept BigInt, but the code does work correctly.
    expect(bigDecimal.toString()).to.equal('123456789123456');
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

describe('BigDecimal Edge Cases', () => {
  describe('Negative number arithmetic', () => {
    it('should add negative and positive', () => {
      const a = new BigDecimal(-10);
      const b = new BigDecimal(3);
      expect(a.plus(b).toString()).to.equal('-7');
    });

    it('should subtract larger from smaller', () => {
      const a = new BigDecimal(3);
      const b = new BigDecimal(10);
      expect(a.minus(b).toString()).to.equal('-7');
    });

    it('should multiply two negatives', () => {
      const a = new BigDecimal(-3);
      const b = new BigDecimal(-4);
      expect(a.times(b).toString()).to.equal('12');
    });

    it('should multiply negative by positive', () => {
      const a = new BigDecimal(-3);
      const b = new BigDecimal(4);
      expect(a.times(b).toString()).to.equal('-12');
    });

    it('should divide negative by positive', () => {
      const a = new BigDecimal(-10);
      const b = new BigDecimal(2);
      expect(a.div(b).toString()).to.equal('-5');
    });
  });

  describe('Zero arithmetic', () => {
    it('should add zero and zero', () => {
      const zero = new BigDecimal(0);
      expect(zero.plus(zero).toString()).to.equal('0');
    });

    it('should multiply zero by any number', () => {
      const zero = new BigDecimal(0);
      const big = new BigDecimal(999);
      expect(zero.times(big).toString()).to.equal('0');
    });

    it('should divide zero by non-zero', () => {
      const zero = new BigDecimal(0);
      const five = new BigDecimal(5);
      expect(zero.div(five).toString()).to.equal('0');
    });

    it('should return Infinity for division by zero', () => {
      const ten = new BigDecimal(10);
      const zero = new BigDecimal(0);
      expect(ten.div(zero).toString()).to.equal('Infinity');
    });
  });

  describe('Comparison false cases', () => {
    it('gt should return false when less', () => {
      const a = new BigDecimal(1);
      const b = new BigDecimal(2);
      expect(a.gt(b)).to.be.false;
    });

    it('gt should return false when equal', () => {
      const a = new BigDecimal(5);
      const b = new BigDecimal(5);
      expect(a.gt(b)).to.be.false;
    });

    it('lt should return false when greater', () => {
      const a = new BigDecimal(2);
      const b = new BigDecimal(1);
      expect(a.lt(b)).to.be.false;
    });

    it('lt should return false when equal', () => {
      const a = new BigDecimal(5);
      const b = new BigDecimal(5);
      expect(a.lt(b)).to.be.false;
    });

    it('isEqualTo should return false for different values', () => {
      const a = new BigDecimal(1);
      const b = new BigDecimal(2);
      expect(a.isEqualTo(b)).to.be.false;
    });

    it('gte should return false when less', () => {
      const a = new BigDecimal(1);
      const b = new BigDecimal(2);
      expect(a.gte(b)).to.be.false;
    });

    it('lte should return false when greater', () => {
      const a = new BigDecimal(2);
      const b = new BigDecimal(1);
      expect(a.lte(b)).to.be.false;
    });
  });

  describe('Negative number comparisons', () => {
    it('negative should be less than zero', () => {
      const neg = new BigDecimal(-5);
      const zero = new BigDecimal(0);
      expect(neg.lt(zero)).to.be.true;
    });

    it('negative should be less than positive', () => {
      const neg = new BigDecimal(-5);
      const pos = new BigDecimal(5);
      expect(neg.lt(pos)).to.be.true;
    });

    it('larger negative should be greater than smaller negative', () => {
      const a = new BigDecimal(-1);
      const b = new BigDecimal(-10);
      expect(a.gt(b)).to.be.true;
    });
  });

  describe('Large number precision', () => {
    it('should preserve precision for large decimal strings', () => {
      const a = new BigDecimal('123456789012345678.987654321');
      const b = new BigDecimal('0.000000001');
      expect(a.plus(b).toString()).to.equal('123456789012345678.987654322');
    });

    it('should handle large number multiplication preserving all digits', () => {
      const a = new BigDecimal('123456789012345678');
      const b = new BigDecimal(2);
      expect(a.times(b).toString()).to.equal('246913578024691356');
    });
  });

  describe('Equality across constructors', () => {
    it('int and float should be equal for integer values', () => {
      const a = new BigDecimal(42);
      const b = new BigDecimal(42.0);
      expect(a.isEqualTo(b)).to.be.true;
    });

    it('int and string should be equal', () => {
      const a = new BigDecimal(42);
      const b = new BigDecimal('42');
      expect(a.isEqualTo(b)).to.be.true;
    });

    it('values with trailing zeros should be equal', () => {
      const a = new BigDecimal('1.0');
      const b = new BigDecimal('1.00');
      expect(a.isEqualTo(b)).to.be.true;
    });
  });
});
