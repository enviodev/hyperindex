import { describe, expect, it } from "vitest";
import * as S from "rescript-schema";
import { S as EnvioS } from "envio";
import {
  buildManifest,
  defineEnum,
  defineInput,
  defineScalar,
  defineType,
  toSDL,
} from "envio/src/resolvers/manifest.js";

const BigIntScalar = defineScalar("BigInt", S.string);

const Period = defineEnum("Period", ["Day", "Hour"]);

const Nested = defineType("Nested", { deep: S.string });

const MarketApr = defineType("MarketApr", {
  marketAddress: S.string,
  aprByFee: BigIntScalar,
  nested: S.optional(Nested),
});

const resolver = (over: Record<string, unknown> = {}) => ({
  name: "marketsAprByPeriod",
  description: "APR by market",
  args: {
    periodStart: S.int32,
    period: Period,
    marketAddresses: S.optional(S.array(S.string)),
  },
  output: S.array(MarketApr),
  timeoutMs: 30_000,
  ...over,
});

describe("envio's own scalars", () => {
  // `S.bigint` and `S.bigDecimal` are how a handler already spells these, and
  // resolvers share that vocabulary. Both cross the wire as strings, which is
  // what a 30-digit PnL figure needs.
  it("maps them onto named GraphQL scalars without a defineScalar call", () => {
    const manifest = buildManifest([
      {
        name: "pnl",
        args: { minSize: EnvioS.bigint },
        output: EnvioS.bigDecimal,
        timeoutMs: 1000,
      },
    ]);
    expect(manifest).toEqual({
      schemaVersion: 1,
      resolvers: [
        {
          name: "pnl",
          args: [{ name: "minSize", type: "BigInt!" }],
          type: "BigDecimal!",
          admin: false,
          timeoutMs: 1000,
        },
      ],
      types: [
        { kind: "scalar", name: "BigDecimal" },
        { kind: "scalar", name: "BigInt" },
      ],
    });
  });

  it("keeps them nullable when the declaration is optional", () => {
    const manifest = buildManifest([
      {
        name: "pnl",
        args: {},
        output: S.optional(EnvioS.bigint),
        timeoutMs: 1000,
      },
    ]);
    expect(manifest.resolvers[0]!.type).toEqual("BigInt");
  });
});

describe("resolver manifest", () => {
  // The whole contract in one value: envio-serve's manifest.rs parses exactly
  // this shape, and SCHEMA_VERSION is pinned on both sides.
  it("builds the manifest envio-serve parses", () => {
    expect(buildManifest([resolver()])).toEqual({
      schemaVersion: 1,
      resolvers: [
        {
          name: "marketsAprByPeriod",
          description: "APR by market",
          args: [
            { name: "periodStart", type: "Int!" },
            { name: "period", type: "Period!" },
            { name: "marketAddresses", type: "[String!]" },
          ],
          type: "[MarketApr!]!",
          admin: false,
          timeoutMs: 30_000,
        },
      ],
      // sorted by name, so the manifest is stable across runs
      types: [
        { kind: "scalar", name: "BigInt" },
        {
          kind: "object",
          name: "MarketApr",
          fields: [
            { name: "marketAddress", type: "String!" },
            { name: "aprByFee", type: "BigInt!" },
            { name: "nested", type: "Nested" },
          ],
        },
        { kind: "object", name: "Nested", fields: [{ name: "deep", type: "String!" }] },
        { kind: "enum", name: "Period", values: [{ name: "Day" }, { name: "Hour" }] },
      ],
    });
  });

  // Nullability is inverted relative to Sury: GraphQL fields are non-null
  // unless the schema is optional.
  it("maps scalars, lists and optionality", () => {
    const t = (schema: unknown) =>
      buildManifest([{ name: "probe", args: {}, output: schema, timeoutMs: 1 }])
        .resolvers[0].type;
    expect([
      t(S.string),
      t(S.int32),
      t(S.number),
      t(S.boolean),
      t(S.optional(S.string)),
      t(S.array(S.string)),
      t(S.optional(S.array(S.optional(S.int32)))),
    ]).toEqual([
      "String!",
      "Int!",
      "Float!",
      "Boolean!",
      "String",
      "[String!]!",
      "[Int]",
    ]);
  });

  // An anonymous object cannot become a GraphQL type, and a generated name
  // would leak into the user's public API -- so it has to be an error the
  // user can act on, not a guess.
  it("refuses anonymous object types with an actionable message", () => {
    expect(() =>
      buildManifest([
        { name: "x", args: {}, output: S.schema({ a: S.string }), timeoutMs: 1 },
      ])
    ).toThrow(/must be named.*defineType/s);
  });

  // statement_timeout is the only thing that bounds a runaway query, so it
  // must be declared.
  // It was carried through the manifest and read by nothing. Silently ignoring
  // a caching option is worse than not having one: a resolver author sets it,
  // sees no error, and assumes their expensive query is being cached.
  it("refuses cacheTtlMs rather than accepting an option that does nothing", () => {
    expect(() =>
      buildManifest([
        { name: "x", args: {}, output: S.string, timeoutMs: 1, cacheTtlMs: 60_000 },
      ])
    ).toThrow(/cacheTtlMs.*not implemented/s);
  });

  it("requires a positive timeoutMs", () => {
    expect(() =>
      buildManifest([{ name: "x", args: {}, output: S.string, timeoutMs: 0 }])
    ).toThrow(/positive timeoutMs/);
  });

  it("rejects duplicate and reserved resolver names", () => {
    const one = () => ({ args: {}, output: S.string, timeoutMs: 1 });
    expect(() =>
      buildManifest([
        { name: "a", ...one() },
        { name: "a", ...one() },
      ])
    ).toThrow(/Duplicate resolver 'a'/);
    expect(() => buildManifest([{ name: "__schema", ...one() }])).toThrow(
      /reserved '__' prefix/
    );
  });

  it("rejects two different types sharing a name", () => {
    const A = defineInput("Clash", { a: S.string });
    const B = defineInput("Clash", { b: S.string });
    expect(() =>
      buildManifest([
        { name: "x", args: { a: A, b: B }, output: S.string, timeoutMs: 1 },
      ])
    ).toThrow(/both named 'Clash'/);
  });

  it("renders SDL for humans", () => {
    expect(toSDL(buildManifest([resolver()]))).toMatchInlineSnapshot(`
      "scalar BigInt

      type MarketApr {
        marketAddress: String!
        aprByFee: BigInt!
        nested: Nested
      }

      type Nested {
        deep: String!
      }

      enum Period {
        Day
        Hour
      }

      extend type Query {
        marketsAprByPeriod(periodStart: Int!, period: Period!, marketAddresses: [String!]): [MarketApr!]!
      }
      "
    `);
  });
});

// GraphQL splits its type namespace in two: a type that appears in an argument
// is an `input`, and an object type cannot stand in for one. Nearly every
// resolver in the reference implementation takes a `where` argument, so this is
// the ordinary case rather than an advanced one.
describe("input objects", () => {
  const Where = defineInput("MarketAprsWhereInput", {
    periodStart: S.int32,
    marketAddresses: S.optional(S.array(S.string)),
  });
  const CodeTier = defineInput("CodeTierRuleInput", { tier: S.string, share: S.string });

  it("names an object-shaped argument as an input type", () => {
    const manifest = buildManifest([
      {
        name: "marketsAprByPeriod",
        args: { where: S.optional(Where), codeTiersAsc: S.array(CodeTier) },
        output: S.string,
        timeoutMs: 1,
      },
    ]);
    expect({ args: manifest.resolvers[0].args, types: manifest.types }).toEqual({
      args: [
        { name: "where", type: "MarketAprsWhereInput" },
        { name: "codeTiersAsc", type: "[CodeTierRuleInput!]!" },
      ],
      types: [
        {
          kind: "input_object",
          name: "CodeTierRuleInput",
          fields: [
            { name: "tier", type: "String!" },
            { name: "share", type: "String!" },
          ],
        },
        {
          kind: "input_object",
          name: "MarketAprsWhereInput",
          fields: [
            { name: "periodStart", type: "Int!" },
            { name: "marketAddresses", type: "[String!]" },
          ],
        },
      ],
    });
  });

  it("renders SDL as input, not type", () => {
    expect(
      toSDL(
        buildManifest([
          { name: "x", args: { where: Where }, output: S.string, timeoutMs: 1 },
        ])
      )
    ).toMatchInlineSnapshot(`
      "input MarketAprsWhereInput {
        periodStart: Int!
        marketAddresses: [String!]
      }

      extend type Query {
        x(where: MarketAprsWhereInput!): String!
      }
      "
    `);
  });

  // Both directions are invalid GraphQL, and Hasura would reject the metadata
  // built from them -- with a message that names neither the resolver nor the
  // declaration that caused it.
  it("refuses an output type as an argument, and an input type as a result", () => {
    const Out = defineType("Bucket", { pnl: S.string });
    expect(() =>
      buildManifest([{ name: "x", args: { b: Out }, output: S.string, timeoutMs: 1 }])
    ).toThrow(/'Bucket'.*defineInput/s);
    expect(() =>
      buildManifest([{ name: "x", args: {}, output: Where, timeoutMs: 1 }])
    ).toThrow(/'MarketAprsWhereInput'.*defineType/s);
  });

  it("points an anonymous argument object at defineInput", () => {
    expect(() =>
      buildManifest([
        {
          name: "x",
          args: { where: S.schema({ a: S.string }) },
          output: S.string,
          timeoutMs: 1,
        },
      ])
    ).toThrow(/must be named.*defineInput/s);
  });
});

describe("createResolver", () => {
  // Declaring registers, the same way importing a handler module registers
  // its handlers -- so there is no second export list to keep in sync.
  it("registers declarations and builds their manifest", async () => {
    const { createResolver, getRegisteredResolvers, buildRegisteredManifest, resetResolvers } =
      await import("envio/src/resolvers/index.js");
    resetResolvers();

    const Stat = defineType("Stat2", { pnl: S.string });
    createResolver({
      name: "statsA",
      args: { account: S.string },
      output: S.array(Stat),
      timeoutMs: 1000,
      handler: async () => [],
    });
    createResolver({
      name: "statsB",
      output: S.int32,
      timeoutMs: 2000,
      admin: true,
      handler: async () => 1,
    });

    const { manifest } = buildRegisteredManifest();
    expect([
      getRegisteredResolvers().map((r) => r.name),
      manifest.resolvers.map((r) => [r.name, r.type, r.admin, r.timeoutMs]),
    ]).toEqual([
      ["statsA", "statsB"],
      [
        ["statsA", "[Stat2!]!", false, 1000],
        ["statsB", "Int!", true, 2000],
      ],
    ]);
    resetResolvers();
  });

  // Errors are raised at the declaration so the stack still says which file
  // the bad resolver came from.
  it("validates at declaration time", async () => {
    const { createResolver, resetResolvers } = await import(
      "envio/src/resolvers/index.js"
    );
    resetResolvers();
    const base = { name: "x", output: S.string, timeoutMs: 1, handler: async () => "" };

    expect(() => createResolver({ ...base, name: "" })).toThrow(/non-empty `name`/);
    expect(() => createResolver({ ...base, output: undefined })).toThrow(/`output` schema/);
    expect(() => createResolver({ ...base, handler: undefined })).toThrow(/`handler` function/);
    expect(() => createResolver({ ...base, timeoutMs: 0 })).toThrow(/positive `timeoutMs`/);
    // An unrepresentable schema fails here, not at the end of codegen.
    expect(() =>
      createResolver({ ...base, output: S.schema({ a: S.string }) })
    ).toThrow(/must be named/);

    createResolver(base);
    expect(() => createResolver(base)).toThrow(/declared more than once/);
    resetResolvers();
  });
});
