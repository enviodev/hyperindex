import test from "ava";
import { BigDecimal } from "generated";

test("Should create BigDecimal from BigInt", (t) => {
  const bigDecimal = new BigDecimal(123456789123456n as any); // The upstream types don't accept BigInt, but the code does work correctly.
  t.deepEqual(bigDecimal.toString(), "123456789123456");
});

test("Should create BigDecimal from float", (t) => {
  const bigDecimal = new BigDecimal(123.456);
  t.deepEqual(bigDecimal.toString(), "123.456");
});

test("Should create BigDecimal from int", (t) => {
  const bigDecimal = new BigDecimal(123);
  t.deepEqual(bigDecimal.toString(), "123");
});

test("Should create BigDecimal from string (unsafe)", (t) => {
  const bigDecimal = new BigDecimal("123.456");
  t.deepEqual(bigDecimal.toString(), "123.456");
});

test("Should convert BigDecimal to string", (t) => {
  const bigDecimal = new BigDecimal(123.456);
  t.deepEqual(bigDecimal.toString(), "123.456");
});

test("Should convert BigDecimal to fixed string", (t) => {
  const bigDecimal = new BigDecimal(123.456);
  t.deepEqual(bigDecimal.toFixed(2), "123.46"); // Rounding may vary
});

test("Should convert BigDecimal to int", (t) => {
  const bigDecimal = new BigDecimal(123.456);
  t.deepEqual(bigDecimal.toFixed(0), "123");
});

test("Should perform addition", (t) => {
  const a = new BigDecimal(10);
  const b = new BigDecimal(20);
  const result = a.plus(b);
  t.deepEqual(result.toString(), "30");
});

test("Should perform subtraction", (t) => {
  const a = new BigDecimal(20);
  const b = new BigDecimal(10);
  const result = a.minus(b);
  t.deepEqual(result.toString(), "10");
});

test("Should perform multiplication", (t) => {
  const a = new BigDecimal(2);
  const b = new BigDecimal(3);
  const result = a.times(b);
  t.deepEqual(result.toString(), "6");
});

test("Should perform division", (t) => {
  const a = new BigDecimal(6);
  const b = new BigDecimal(2);
  const result = a.div(b);
  t.deepEqual(result.toString(), "3");
});

test("Should check equality", (t) => {
  const a = new BigDecimal(10);
  const b = new BigDecimal(10);
  t.true(a.isEqualTo(b));
});

test("Should check greater than", (t) => {
  const a = new BigDecimal(20);
  const b = new BigDecimal(10);
  t.true(a.gt(b));
});

test("Should check greater than or equal", (t) => {
  const a = new BigDecimal(20);
  const b = new BigDecimal(10);
  t.true(a.gte(b));
  t.true(a.gte(a));
});

test("Should check less than", (t) => {
  const a = new BigDecimal(10);
  const b = new BigDecimal(20);
  t.true(a.lt(b));
});

test("Should check less than or equal", (t) => {
  const a = new BigDecimal(10);
  const b = new BigDecimal(20);
  t.true(a.lte(b));
  t.true(a.lte(a));
});
