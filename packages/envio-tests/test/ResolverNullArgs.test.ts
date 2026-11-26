import { describe, expect, it } from "vitest";
import * as Sury from "rescript-schema";
import { S } from "envio";
import {
  buildManifest,
  createResolver,
  defineEnum,
  defineInput,
  defineScalar,
} from "envio/src/resolvers/index.js";
import { createDispatcher } from "envio/src/resolvers/dispatch.js";

// A nullable GraphQL argument may be sent as `null` or left out, and a client
// cannot always choose which: Hasura delivers a variable the caller did not
// provide as `null`. Every position the manifest publishes as nullable has to
// take both, and every position it publishes as required has to keep refusing
// them. The dispatcher is called directly because the argument values are the
// thing under test; `ResolverHasuraAction.test.ts` covers the same over HTTP.

// What the handler was handed, with the two values JSON cannot tell apart from
// absence spelled out.
const show = (value: unknown) =>
  JSON.parse(
    JSON.stringify(value, (_key, item) =>
      typeof item === "bigint" ? `${item}n` : item === undefined ? "<undefined>" : item
    )
  );

const Direction = defineEnum("NullArgsDirection", ["asc", "desc"]);
const Json = defineScalar("NullArgsJson", Sury.unknown);
const Tags = defineScalar("NullArgsTags", S.array(S.optional(S.string)));
const Range = defineInput("NullArgsRange", {
  from: S.int32,
  to: S.optional(S.int32),
});
const Where = defineInput("NullArgsWhere", {
  account: S.string,
  minSize: S.optional(S.bigint),
  direction: S.optional(Direction),
  range: S.optional(Range),
  ranges: S.optional(S.array(Range)),
  limit: S.optional(S.int32, 50),
  meta: S.optional(Json),
});

// An input type that lists itself, declared the only way one can be: the
// fields are parsed as written, and the published ones are patched to name the
// type once it exists.
const Filter = defineInput("NullArgsFilter", {
  to: S.optional(S.int32),
  AND: S.optional(S.array(Sury.unknown)),
});
(Filter as unknown as Record<symbol, { fields: Record<string, unknown> }>)[
  Symbol.for("envio.resolvers.graphqlType")
]!.fields.AND = S.optional(S.array(Filter));

const declare = (name: string, args: Record<string, unknown>) =>
  createResolver({
    name,
    args,
    output: S.string,
    timeoutMs: 5_000,
    handler: async ({ args: parsed }: { args: unknown }) => JSON.stringify(show(parsed)),
  });

const resolvers = [
  declare("nullArgsOptional", { to: S.optional(S.int32) }),
  declare("nullArgsDefault", { to: S.optional(S.int32, 7) }),
  declare("nullArgsNullTyped", { to: Sury.nullable(S.int32) }),
  declare("nullArgsNullish", { to: Sury.nullish(S.int32) }),
  declare("nullArgsNullOverDefault", { to: Sury.nullable(S.optional(S.int32, 7)) }),
  declare("nullArgsNullTypedInput", { range: Sury.nullable(Range) }),
  declare("nullArgsNested", { to: S.optional(S.optional(S.int32)) }),
  declare("nullArgsRequired", { to: S.int32, where: Where }),
  declare("nullArgsBigInt", { size: S.optional(S.bigint) }),
  declare("nullArgsEnum", { direction: S.optional(Direction) }),
  declare("nullArgsWhere", { where: S.optional(Where) }),
  declare("nullArgsList", { ids: S.optional(S.array(S.int32)) }),
  declare("nullArgsElements", { ids: S.array(S.optional(S.int32)) }),
  declare("nullArgsBoth", { ids: S.optional(S.array(S.optional(S.int32))) }),
  declare("nullArgsInputs", { ranges: S.array(S.optional(Range)) }),
  declare("nullArgsJson", { meta: S.optional(Json), strict: Json }),
  declare("nullArgsOpaque", { tags: S.optional(Tags) }),
  declare("nullArgsRefined", {
    to: S.optional(
      Sury.refine(S.int32, (value, s) => {
        if (value < 0) s.fail("must not be negative");
      })
    ),
  }),
  declare("nullArgsFilter", { filter: S.optional(Filter) }),
  declare("nullArgsNone", { account: S.string, size: S.bigint }),
];

const dispatch = createDispatcher({
  resolvers,
  pool: { forResolver: () => ({}) },
  exposeErrors: true,
});

type Answer = { data?: string; errors?: Array<{ message: string; extensions: { code: string } }> };

const resolve = (field: string, args?: unknown): Promise<Answer> =>
  dispatch({ field, args, selection: {}, role: "public", requestId: "test" });

/** The arguments the handler received, or the error code it never got as far as. */
const call = async (field: string, args?: unknown) => {
  const answer = await resolve(field, args);
  return answer.errors === undefined
    ? { args: JSON.parse(answer.data as string) }
    : { code: answer.errors[0]!.extensions.code };
};

const ABSENT = "<undefined>";

describe("resolver arguments: null and absent", () => {
  it("reads null as absent for an optional argument", async () => {
    expect({
      null: await call("nullArgsOptional", { to: null }),
      absent: await call("nullArgsOptional", {}),
      noArgs: await call("nullArgsOptional"),
      value: await call("nullArgsOptional", { to: 3 }),
      zero: await call("nullArgsOptional", { to: 0 }),
    }).toEqual({
      null: { args: { to: ABSENT } },
      absent: { args: { to: ABSENT } },
      noArgs: { args: { to: ABSENT } },
      value: { args: { to: 3 } },
      zero: { args: { to: 0 } },
    });
  });

  it("applies an optional argument's default to null as it does to absence", async () => {
    expect({
      null: await call("nullArgsDefault", { to: null }),
      absent: await call("nullArgsDefault", {}),
      value: await call("nullArgsDefault", { to: 3 }),
    }).toEqual({
      null: { args: { to: 7 } },
      absent: { args: { to: 7 } },
      value: { args: { to: 3 } },
    });
  });

  it("reads absence as null for a null-typed argument", async () => {
    expect({
      null: await call("nullArgsNullTyped", { to: null }),
      absent: await call("nullArgsNullTyped", {}),
      value: await call("nullArgsNullTyped", { to: 3 }),
    }).toEqual({
      null: { args: { to: ABSENT } },
      absent: { args: { to: ABSENT } },
      value: { args: { to: 3 } },
    });
  });

  it("leaves a schema that already takes both as it was", async () => {
    expect({
      nullishNull: await call("nullArgsNullish", { to: null }),
      nullishAbsent: await call("nullArgsNullish", {}),
      nestedNull: await call("nullArgsNested", { to: null }),
      nestedAbsent: await call("nullArgsNested", {}),
      nestedValue: await call("nullArgsNested", { to: 3 }),
      // Absence already reaches the default here; rewriting it to null would
      // lose it.
      defaultAbsent: await call("nullArgsNullOverDefault", {}),
      defaultNull: await call("nullArgsNullOverDefault", { to: null }),
    }).toEqual({
      defaultAbsent: { args: { to: 7 } },
      defaultNull: { args: { to: ABSENT } },
      nullishNull: { args: { to: ABSENT } },
      nullishAbsent: { args: { to: ABSENT } },
      nestedNull: { args: { to: ABSENT } },
      nestedAbsent: { args: { to: ABSENT } },
      nestedValue: { args: { to: 3 } },
    });
  });

  it("still converts and validates a value that is given", async () => {
    expect({
      bigint: await call("nullArgsBigInt", { size: "250" }),
      bigintNull: await call("nullArgsBigInt", { size: null }),
      bigintWrong: await call("nullArgsBigInt", { size: 250 }),
      enumValue: await call("nullArgsEnum", { direction: "desc" }),
      enumNull: await call("nullArgsEnum", { direction: null }),
      enumWrong: await call("nullArgsEnum", { direction: "sideways" }),
      wrongType: await call("nullArgsOptional", { to: "3" }),
      refined: await call("nullArgsRefined", { to: 3 }),
      refinedNull: await call("nullArgsRefined", { to: null }),
      refinedRefused: await call("nullArgsRefined", { to: -1 }),
    }).toEqual({
      bigint: { args: { size: "250n" } },
      bigintNull: { args: { size: ABSENT } },
      bigintWrong: { code: "BAD_USER_INPUT" },
      enumValue: { args: { direction: "desc" } },
      enumNull: { args: { direction: ABSENT } },
      enumWrong: { code: "BAD_USER_INPUT" },
      wrongType: { code: "BAD_USER_INPUT" },
      refined: { args: { to: 3 } },
      refinedNull: { args: { to: ABSENT } },
      refinedRefused: { code: "BAD_USER_INPUT" },
    });
  });

  it("keeps refusing null and absence for a required argument", async () => {
    const where = { account: "0xaaa" };
    expect({
      null: await call("nullArgsRequired", { to: null, where }),
      absent: await call("nullArgsRequired", { where }),
      whereNull: await call("nullArgsRequired", { to: 1, where: null }),
      whereAbsent: await call("nullArgsRequired", { to: 1 }),
      fieldNull: await call("nullArgsRequired", { to: 1, where: { account: null } }),
      fieldAbsent: await call("nullArgsRequired", { to: 1, where: {} }),
      elementNull: await call("nullArgsList", { ids: [1, null] }),
      requiredInOptional: await call("nullArgsWhere", { where: { account: null } }),
      requiredInElement: await call("nullArgsInputs", { ranges: [{ from: null }] }),
      noNullable: await call("nullArgsNone", { account: "0xaaa", size: null }),
    }).toEqual({
      null: { code: "BAD_USER_INPUT" },
      absent: { code: "BAD_USER_INPUT" },
      whereNull: { code: "BAD_USER_INPUT" },
      whereAbsent: { code: "BAD_USER_INPUT" },
      fieldNull: { code: "BAD_USER_INPUT" },
      fieldAbsent: { code: "BAD_USER_INPUT" },
      elementNull: { code: "BAD_USER_INPUT" },
      requiredInOptional: { code: "BAD_USER_INPUT" },
      requiredInElement: { code: "BAD_USER_INPUT" },
      noNullable: { code: "BAD_USER_INPUT" },
    });
  });

  it("reads null as absent for an optional input object and for each optional field in one", async () => {
    const empty = {
      account: "0xaaa",
      minSize: ABSENT,
      direction: ABSENT,
      range: ABSENT,
      ranges: ABSENT,
      limit: 50,
      meta: ABSENT,
    };
    expect({
      whereNull: await call("nullArgsWhere", { where: null }),
      whereAbsent: await call("nullArgsWhere", {}),
      // What a client that leaves every variable out sends through Hasura.
      everyFieldNull: await call("nullArgsWhere", {
        where: {
          account: "0xaaa",
          minSize: null,
          direction: null,
          range: null,
          ranges: null,
          limit: null,
        },
      }),
      everyFieldAbsent: await call("nullArgsWhere", { where: { account: "0xaaa" } }),
      nested: await call("nullArgsWhere", {
        where: {
          account: "0xaaa",
          minSize: "5",
          range: { from: 1, to: null },
          ranges: [{ from: 2, to: null }, { from: 3, to: 4 }],
          limit: 10,
        },
      }),
      required: await call("nullArgsRequired", { to: 1, where: { account: "0xaaa", range: null } }),
      nullTyped: await call("nullArgsNullTypedInput", { range: { from: 1, to: null } }),
      nullTypedAbsent: await call("nullArgsNullTypedInput", {}),
    }).toEqual({
      nullTyped: { args: { range: { from: 1, to: ABSENT } } },
      nullTypedAbsent: { args: { range: ABSENT } },
      whereNull: { args: { where: ABSENT } },
      whereAbsent: { args: { where: ABSENT } },
      everyFieldNull: { args: { where: empty } },
      everyFieldAbsent: { args: { where: empty } },
      nested: {
        args: {
          where: {
            ...empty,
            minSize: "5n",
            range: { from: 1, to: ABSENT },
            ranges: [{ from: 2, to: ABSENT }, { from: 3, to: 4 }],
            limit: 10,
          },
        },
      },
      required: { args: { to: 1, where: empty } },
    });
  });

  it("reads a null element as absent where the list declares optional elements", async () => {
    expect({
      listNull: await call("nullArgsList", { ids: null }),
      listValue: await call("nullArgsList", { ids: [1, 2] }),
      elements: await call("nullArgsElements", { ids: [1, null, 3] }),
      elementsRequiredList: await call("nullArgsElements", { ids: null }),
      bothNull: await call("nullArgsBoth", { ids: null }),
      bothElements: await call("nullArgsBoth", { ids: [null] }),
      inputs: await call("nullArgsInputs", { ranges: [null, { from: 1, to: null }] }),
      empty: await call("nullArgsElements", { ids: [] }),
    }).toEqual({
      listNull: { args: { ids: ABSENT } },
      listValue: { args: { ids: [1, 2] } },
      elements: { args: { ids: [1, ABSENT, 3] } },
      elementsRequiredList: { code: "BAD_USER_INPUT" },
      bothNull: { args: { ids: ABSENT } },
      bothElements: { args: { ids: [ABSENT] } },
      inputs: { args: { ranges: [ABSENT, { from: 1, to: ABSENT }] } },
      empty: { args: { ids: [] } },
    });
  });

  it("hands a scalar that takes null the caller's null, and does not look inside a named scalar", async () => {
    expect({
      // A JSON value may itself be null, so the handler is still told which
      // the caller sent.
      jsonNull: await call("nullArgsJson", { meta: null, strict: null }),
      jsonAbsent: await call("nullArgsJson", { strict: 1 }),
      jsonValue: await call("nullArgsJson", { meta: { a: [null] }, strict: { b: null } }),
      jsonInInput: await call("nullArgsWhere", { where: { account: "0xaaa", meta: null } }),
      opaqueNull: await call("nullArgsOpaque", { tags: null }),
      // The scalar's own schema decides what its value may hold; a null inside
      // it is not a nullable position the manifest publishes.
      opaqueInside: await call("nullArgsOpaque", { tags: ["a", null] }),
    }).toEqual({
      jsonNull: { args: { meta: null, strict: null } },
      jsonAbsent: { args: { meta: ABSENT, strict: 1 } },
      jsonValue: { args: { meta: { a: [null] }, strict: { b: null } } },
      jsonInInput: {
        args: {
          where: {
            account: "0xaaa",
            minSize: ABSENT,
            direction: ABSENT,
            range: ABSENT,
            ranges: ABSENT,
            limit: 50,
            meta: null,
          },
        },
      },
      opaqueNull: { args: { tags: ABSENT } },
      opaqueInside: { code: "BAD_USER_INPUT" },
    });
  });

  it("follows an input type that lists itself, to any depth", async () => {
    expect({
      null: await call("nullArgsFilter", { filter: null }),
      flat: await call("nullArgsFilter", { filter: { to: null, AND: null } }),
      deep: await call("nullArgsFilter", {
        filter: { to: 1, AND: [{ to: null, AND: [{ to: null }, { to: 2, AND: null }] }] },
      }),
    }).toEqual({
      null: { args: { filter: ABSENT } },
      flat: { args: { filter: { to: ABSENT, AND: ABSENT } } },
      deep: {
        args: {
          filter: {
            to: 1,
            AND: [{ to: ABSENT, AND: [{ to: ABSENT }, { to: 2, AND: ABSENT }] }],
          },
        },
      },
    });
  });

  it("leaves the request's own arguments untouched", async () => {
    const args = {
      where: {
        account: "0xaaa",
        minSize: null,
        range: { from: 1, to: null },
        ranges: [{ from: 2, to: null }],
      },
    };
    const before = JSON.stringify(args);
    const elements = { ids: [1, null] };
    await resolve("nullArgsWhere", args);
    await resolve("nullArgsElements", elements);
    expect({ args: JSON.stringify(args), elements }).toEqual({
      args: before,
      elements: { ids: [1, null] },
    });
  });

  it("answers the same on every call", async () => {
    const args = { where: { account: "0xaaa", range: { from: 1, to: null } } };
    const first = await call("nullArgsWhere", args);
    expect([await call("nullArgsWhere", args), await call("nullArgsWhere", args)]).toEqual([
      first,
      first,
    ]);
  });
});

// The check that keeps the parser and the published schema from drifting apart
// again: every position is found by walking the manifest, not the schemas, and
// is then sent null, nothing, and a value.
describe("resolver arguments: a resolver object without args", () => {
  // `createResolver` always fills `args` in; the manifest and the argument
  // schema both read a missing one as "no arguments", and so does this.
  it("dispatches a resolver whose args were never set", async () => {
    const { args: _args, ...withoutArgs } = declare("nullArgsNoArgsKey", {});
    const dispatchWithoutArgs = createDispatcher({
      resolvers: [withoutArgs as ReturnType<typeof declare>],
      pool: { forResolver: () => ({}) },
      exposeErrors: true,
    });
    const request = { selection: {}, role: "public", requestId: "test" };
    expect({
      noArgs: await dispatchWithoutArgs({ ...request, field: "nullArgsNoArgsKey" }),
      empty: await dispatchWithoutArgs({ ...request, field: "nullArgsNoArgsKey", args: {} }),
    }).toEqual({ noArgs: { data: "{}" }, empty: { data: "{}" } });
  });
});

describe("resolver arguments: every published position", () => {
  const manifest = buildManifest(resolvers) as {
    resolvers: Array<{ name: string; args: Array<{ name: string; type: string }> }>;
    types: Array<{
      kind: string;
      name: string;
      values?: Array<{ name: string }>;
      fields?: Array<{ name: string; type: string }>;
    }>;
  };
  const types = new Map(manifest.types.map((type) => [type.name, type]));

  const SCALARS: Record<string, unknown> = {
    Int: 1,
    Float: 1.5,
    String: "text",
    Boolean: true,
    BigInt: "5",
    NullArgsJson: { any: "thing" },
    NullArgsTags: ["a"],
  };

  const required = (type: string) => type.endsWith("!");
  const bare = (type: string) => (required(type) ? type.slice(0, -1) : type);
  const element = (type: string) => (bare(type).startsWith("[") ? bare(type).slice(1, -1) : null);

  /**
   * A value the type accepts, with every field and one element present. A list
   * of the type it sits in is left empty, which is where a type that lists
   * itself stops.
   */
  const sample = (type: string, within: string[] = []): unknown => {
    const inner = element(type);
    if (inner !== null) return within.includes(bare(inner)) ? [] : [sample(inner, within)];
    const name = bare(type);
    const declared = types.get(name);
    if (declared?.kind === "enum") return declared.values![0]!.name;
    if (declared?.kind === "input_object") {
      return Object.fromEntries(
        declared.fields!.map((field) => [field.name, sample(field.type, [...within, name])])
      );
    }
    if (!(name in SCALARS)) throw new Error(`no sample for '${name}'`);
    return SCALARS[name];
  };

  type Position = {
    path: string;
    nullable: boolean;
    /** The resolver's arguments with this position set to `value`, or removed. */
    build: (value: unknown, remove: boolean) => Record<string, unknown>;
    removable: boolean;
  };

  const positions: Array<Position & { field: string }> = [];

  // `put` rebuilds the enclosing value around a replacement for this position.
  const walk = (
    field: string,
    path: string,
    type: string,
    removable: boolean,
    put: (value: unknown, remove: boolean) => Record<string, unknown>,
    within: string[] = []
  ) => {
    positions.push({ field, path, nullable: !required(type), build: put, removable });
    const inner = element(type);
    if (inner !== null) {
      walk(field, `${path}[]`, inner, false, (value) => put([value], false), within);
      return;
    }
    const name = bare(type);
    const declared = types.get(name);
    // One level of a type that lists itself: the second is the same positions.
    if (declared?.kind !== "input_object" || within.filter((seen) => seen === name).length > 1) return;
    for (const child of declared.fields!) {
      walk(field, `${path}.${child.name}`, child.type, true, (value, remove) => {
        const object = sample(type) as Record<string, unknown>;
        if (remove) delete object[child.name];
        else object[child.name] = value;
        return put(object, false);
      }, [...within, name]);
    }
  };

  for (const resolver of manifest.resolvers) {
    const whole = () =>
      Object.fromEntries(resolver.args.map((arg) => [arg.name, sample(arg.type)]));
    for (const arg of resolver.args) {
      walk(resolver.name, `${resolver.name}(${arg.name})`, arg.type, true, (value, remove) => {
        const args = whole();
        if (remove) delete args[arg.name];
        else args[arg.name] = value;
        return args;
      });
    }
  }

  it("finds the positions the fixtures declare", () => {
    expect({
      total: positions.length,
      nullable: positions.filter((position) => position.nullable).length,
    }).toEqual({ total: 61, nullable: 41 });
  });

  it("accepts a value at every position", async () => {
    const refused: string[] = [];
    for (const resolver of manifest.resolvers) {
      const args = Object.fromEntries(resolver.args.map((arg) => [arg.name, sample(arg.type)]));
      if ((await resolve(resolver.name, args)).errors !== undefined) refused.push(resolver.name);
    }
    expect(refused).toEqual([]);
  });

  it("accepts null and absence where the type is nullable, and refuses them where it is not", async () => {
    const wrong: string[] = [];
    for (const position of positions) {
      const accepted = async (args: Record<string, unknown>) =>
        (await resolve(position.field, args)).errors === undefined;
      const outcomes = {
        null: await accepted(position.build(null, false)),
        // An array element cannot be left out, only sent as null.
        absent: position.removable
          ? await accepted(position.build(undefined, true))
          : position.nullable,
      };
      const expected = { null: position.nullable, absent: position.nullable };
      // A scalar over `unknown`, published as required: it takes any value,
      // null and undefined among them, and always has.
      if (position.path === "nullArgsJson(strict)") {
        expected.null = true;
        expected.absent = true;
      }
      // The patched type parses its own list as `unknown`, so the list's
      // elements are checked by nothing: what it publishes there is the
      // declaration's own promise, not one the parser can keep.
      if (position.path.endsWith(".AND[]")) expected.null = true;
      if (JSON.stringify(outcomes) !== JSON.stringify(expected)) {
        wrong.push(`${position.path}: ${JSON.stringify(outcomes)}`);
      }
    }
    expect(wrong).toEqual([]);
  });
});
