import { describe, expect, it } from "vitest";
import BigNumber from "bignumber.js";
import {
  bucketsBetween,
  compileAggregation,
  compileExpression,
  rollupBucket,
  storedValue,
  type AggregationDef,
} from "../../envio/src/subgraph/aggregations.ts";

const column = (field: string) => field;
const isInteger = (field: string) => field.startsWith("n");
const evaluate = (source: string, row: Record<string, unknown>) => {
  const value: any = compileExpression(source, column, isInteger)(row);
  return value !== null && typeof value === "object" ? value.v.toFixed() : value;
};

describe("aggregate expressions", () => {
  it("evaluates the SQL subset graph-node documents", () => {
    const row = {
      price: new BigNumber("2.5"),
      amount: 4n,
      n1: 7,
      n2: 2,
      zero: 0n,
      missing: null,
    };
    expect({
      product: evaluate("price * amount", row),
      precedence: evaluate("1 + 2 * 3 - 4 / 2", row),
      integerDivision: evaluate("n1 / n2", row),
      numericDivision: evaluate("amount / 8", row),
      greatest: evaluate("greatest(amount, price, 0)", row),
      least: evaluate("least(amount, price)", row),
      caseWhen: evaluate("case when amount > price then amount else 0 end", row),
      coalesce: evaluate("coalesce(missing, price)", row),
      nullPropagates: evaluate("missing + 1", row),
      isNull: evaluate("missing is null", row),
      power: evaluate("2 ^ 10", row),
      abs: evaluate("abs(0 - amount)", row),
      modulo: evaluate("mod(n1, n2)", row),
      nullif: evaluate("nullif(amount, 4)", row),
    }).toEqual({
      product: "10",
      precedence: "5",
      integerDivision: "3",
      numericDivision: "0.5",
      greatest: "4",
      least: "2.5",
      caseWhen: "4",
      coalesce: "2.5",
      nullPropagates: null,
      isNull: true,
      power: "1024",
      abs: "4",
      modulo: "1",
      nullif: null,
    });
  });

  it("refuses what graph-node refuses", () => {
    expect(() => compileExpression("pg_sleep(1)", column, isInteger)).toThrow("the function pg_sleep");
  });
});

describe("buckets", () => {
  // 2006-07-16 07:40Z, as graph-node's own test uses
  const start = 1153035600n * 1_000_000n;
  const eight = 1153036800n * 1_000_000n;
  const hour = 3_600_000_000n;

  it("lists the buckets that end before the second time, oldest first", () => {
    expect({
      sameBucket: bucketsBetween(start, start + 1n, "hour"),
      oneHour: bucketsBetween(start, eight, "hour"),
      twoHours: bucketsBetween(start, start + 2n * hour, "hour"),
      day: bucketsBetween(start, start + 2n * hour, "day"),
    }).toEqual({
      sameBucket: [],
      oneHour: [{ start: eight - hour, end: eight }],
      twoHours: [
        { start: eight - hour, end: eight },
        { start: eight, end: eight + hour },
      ],
      day: [],
    });
  });
});

describe("rolling a bucket up", () => {
  const def: AggregationDef = {
    name: "S",
    source: "D",
    intervals: ["hour"],
    dimensions: [{ field: "token", column: "token_id" }],
    aggregates: [
      { field: "sum", func: "sum", arg: "price", cumulative: false, kind: "BigDecimal" },
      { field: "count", func: "count", cumulative: true, kind: "Int8" },
      { field: "first", func: "first", arg: "price", cumulative: false, kind: "BigDecimal" },
      { field: "last", func: "last", arg: "price", cumulative: false, kind: "BigDecimal" },
      { field: "min", func: "min", arg: "price", cumulative: false, kind: "BigDecimal" },
      { field: "max", func: "max", arg: "price", cumulative: true, kind: "BigDecimal" },
    ],
  };
  const compiled = compileAggregation(def, { kinds: { price: "BigDecimal" }, refs: new Set(["token"]) });
  const row = (id: number, token: string, price: string | null) => ({
    id: String(id),
    token_id: token,
    price: price === null ? null : new BigNumber(price),
  });
  const show = (rows: ReturnType<typeof rollupBucket>) =>
    rows.map((r) => ({
      id: r.id,
      token: r.dimensions.token_id,
      ...Object.fromEntries(
        def.aggregates.map((a) => [a.field, storedValue(r.values[a.field], a.kind)?.toString() ?? null]),
      ),
      next: r.next,
    }));

  it("groups by dimension, orders first and last by id, and skips nulls", () => {
    // Rows arrive out of id order; first and last go by id.
    const rows = [row(30, "A", "3"), row(10, "A", null), row(20, "A", "1"), row(40, "B", "5"), row(5, "A", "7")];
    expect(show(rollupBucket(compiled, rows, () => null))).toEqual([
      { id: 30n, token: "A", sum: "11", count: "4", first: "7", last: "3", min: "1", max: "7", next: { count: "4", max: "7" } },
      { id: 40n, token: "B", sum: "5", count: "1", first: "5", last: "5", min: "5", max: "5", next: { count: "1", max: "5" } },
    ]);
  });

  it("carries a group's cumulative aggregates from its previous bucket", () => {
    const prev = (key: string) => (key === JSON.stringify(["A"]) ? { count: "10", max: "9" } : null);
    expect(show(rollupBucket(compiled, [row(1, "A", "4"), row(2, "B", "2")], prev))).toEqual([
      { id: 1n, token: "A", sum: "4", count: "11", first: "4", last: "4", min: "4", max: "9", next: { count: "11", max: "9" } },
      { id: 2n, token: "B", sum: "2", count: "1", first: "2", last: "2", min: "2", max: "2", next: { count: "1", max: "2" } },
    ]);
  });
});
