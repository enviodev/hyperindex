import assert from "assert";
import { it } from "mocha";
import { S } from "envio";

describe("rescript-schema reexport", () => {
  it("S.parseOrThrow parses primitives", () => {
    const str = S.parseOrThrow("hello", S.string);
    assert.strictEqual(str, "hello");

    const num = S.parseOrThrow(42, S.number);
    assert.strictEqual(num, 42);

    // TODO: Should be a native bigint schema
    // after we start using rescript-schema with built-in JSON transformations
    const bi = S.parseOrThrow("10", S.bigint);
    assert.strictEqual(bi, 10n);
  });

  it("S.parseOrThrow throws on invalid input", () => {
    assert.throws(() => S.parseOrThrow(123, S.string));
  });

  it("S.parseOrThrow parses object schema with optional field", () => {
    const schema = S.schema({
      a: S.string,
      b: S.optional(S.number),
    });

    const value = S.parseOrThrow({ a: "x" }, schema);
    assert.strictEqual(value.a, "x");
    // Optional field should be undefined when omitted
    // Accessing missing property returns undefined in JS
    // so this assertion is robust regardless of property presence
    assert.strictEqual((value as any).b, undefined);
  });

  it("S.parseOrThrow parses union enums and rejects invalid values", () => {
    const enumSchema = S.union(["foo", "bar"]);

    const ok = S.parseOrThrow("foo", enumSchema);
    assert.strictEqual(ok, "foo");

    assert.throws(() => S.parseOrThrow("baz", enumSchema));
  });
});
