open Vitest

// The resolver surface as a user's editor sees it. Every case here is a
// type-check of real user source against the real `envio` types — nothing runs.

let configYaml = `
name: resolver-types
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`

let schema = `
type Position {
  id: ID!
  account: String! @index
  sizeInUsd: BigInt!
  isLong: Boolean!
}
`

let check = handlers => InternalTestIndexer.fromUserApi(~schema, ~handlers, ~configYaml)->ignore

let checkPerChain = handlers =>
  InternalTestIndexer.fromUserApi(
    ~schema,
    ~handlers,
    ~configYaml=configYaml ++ "disable_default_cross_chain: true\n",
  )->ignore

describe("Resolver API types", () => {
  it("infers handler args from the declared arg schemas", _ =>
    check(`
import { createResolver, defineEnum, S } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

const Period = defineEnum("Period", ["Day", "Hour"]);
expectType<TypeEqual<S.Output<typeof Period>, "Day" | "Hour">>(true);

createResolver({
  name: "marketsAprByPeriod",
  args: {
    periodStart: S.int32,
    period: Period,
    marketAddresses: S.optional(S.array(S.string)),
  },
  output: S.array(S.string),
  timeoutMs: 30_000,
  handler: async ({ args }) => {
    expectType<TypeEqual<typeof args.periodStart, number>>(true);
    expectType<TypeEqual<typeof args.period, "Day" | "Hour">>(true);
    expectType<TypeEqual<typeof args.marketAddresses, string[] | undefined>>(true);
    return [];
  },
});
`)
  )

  it("names a nested output type without losing its shape", _ =>
    check(`
import { createResolver, defineScalar, defineType, S } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

const BigIntScalar = defineScalar("BigInt", S.string);
const MarketApr = defineType("MarketApr", {
  marketAddress: S.string,
  aprByFee: BigIntScalar,
});

expectType<TypeEqual<S.Output<typeof MarketApr>, { marketAddress: string; aprByFee: string }>>(
  true
);

createResolver({
  name: "marketsApr",
  output: S.array(MarketApr),
  timeoutMs: 30_000,
  handler: async () => [{ marketAddress: "0x", aprByFee: "1" }],
});
`)
  )

  it("rejects a handler whose result isn't the declared output", _ =>
    check(`
import { createResolver, S } from "envio";

createResolver({
  name: "wrongShape",
  output: S.array(S.string),
  timeoutMs: 30_000,
  // @ts-expect-error - the output schema says string[], not number[]
  handler: async () => [1, 2, 3],
});
`)
  )

  it("requires a timeout on the declaration itself", _ =>
    check(`
import { createResolver, S } from "envio";

// @ts-expect-error - timeoutMs is required: it is the only bound on the query
createResolver({
  name: "unbounded",
  output: S.string,
  handler: async () => "",
});
`)
  )

  it("types the entity loaders off the project schema", _ =>
    check(`
import { createResolver, S } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

createResolver({
  name: "positions",
  args: { account: S.string },
  output: S.array(S.string),
  timeoutMs: 30_000,
  handler: async ({ args, db }) => {
    const positions = await db.find("Position", {
      where: { account: { _eq: args.account }, sizeInUsd: { _gte: 0n } },
      orderBy: [{ field: "sizeInUsd", direction: "desc" }],
      limit: 10,
    });
    expectType<
      TypeEqual<
        typeof positions,
        { readonly id: string; readonly account: string; readonly sizeInUsd: bigint; readonly isLong: boolean }[]
      >
    >(true);

    const one = await db.get("Position", "p1");
    expectType<
      TypeEqual<
        typeof one,
        {
          readonly id: string;
          readonly account: string;
          readonly sizeInUsd: bigint;
          readonly isLong: boolean;
        } | null
      >
    >(true);

    // @ts-expect-error - "Postion" is not an entity in the schema
    await db.find("Postion");

    // @ts-expect-error - sizeInUsd is a BigInt, not a string
    await db.find("Position", { where: { sizeInUsd: { _eq: "0" } } });

    // @ts-expect-error - the entity has no such field
    await db.find("Position", { where: { acount: { _eq: "0x" } } });

    return positions.map((p) => p.id);
  },
});
`)
  )

  it("refuses a bare get on a per-chain entity at compile time", _ =>
    checkPerChain(`
import { createResolver, S } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

createResolver({
  name: "perChain",
  output: S.array(S.string),
  timeoutMs: 30_000,
  handler: async ({ db }) => {
    // A per-chain row is only identified together with its chain.
    const positions = await db.find("Position");
    expectType<TypeEqual<(typeof positions)[number]["chainId"], number>>(true);

    // @ts-expect-error - id alone is not this entity's key; filter by chain with find
    await db.get("Position", "p1");

    return positions.map((p) => p.id);
  },
});
`)
  )

  it("carries the request's own metadata and the freshness watermark", _ =>
    check(`
import { createResolver, S } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

createResolver({
  name: "fresh",
  output: S.boolean,
  admin: true,
  cacheTtlMs: 60_000,
  description: "Whether chain 1337 has caught up",
  timeoutMs: 5_000,
  handler: async ({ db, selection, ctx }) => {
    expectType<TypeEqual<typeof ctx.role, "public" | "admin">>(true);
    expectType<TypeEqual<typeof ctx.requestId, string>>(true);
    expectType<TypeEqual<typeof selection, import("envio").ResolverSelection>>(true);

    const heights = await db.chainHeights();
    const chain = heights["1337"];
    expectType<TypeEqual<typeof chain, import("envio").ChainHeight | undefined>>(true);

    const rows = await db.sql.unsafe<{ n: number }>("SELECT 1::int AS n;");
    expectType<TypeEqual<typeof rows, { n: number }[]>>(true);

    return chain?.isReady ?? false;
  },
});
`)
  )
})
