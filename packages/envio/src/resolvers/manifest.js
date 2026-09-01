// Builds the resolver manifest `envio serve` reads.
//
// Resolvers declare their arguments and result with the same `S` schemas
// effects already use, so there is one schema language in the project rather
// than a second one invented for GraphQL. This module walks those schemas
// into GraphQL types.
//
// The output shape is a contract with envio-serve's `resolvers/manifest.rs`,
// which validates it and fails startup on anything it does not understand.
// SCHEMA_VERSION must be bumped in both places together.

import * as S from "rescript-schema";
import { $$BigInt as UtilsBigInt } from "../Utils.res.mjs";
import { schema as bigDecimalSchema } from "../bindings/BigDecimal.res.mjs";

export const SCHEMA_VERSION = 1;

const GQL_NAME = /^[_A-Za-z][_0-9A-Za-z]*$/;

// Sury tags for the scalars that map onto a GraphQL built-in. Everything
// else has to be named explicitly, because GraphQL has no anonymous types
// and a generated name would leak into a public API.
const BUILTIN_SCALARS = {
  string: "String",
  int32: "Int",
  number: "Float",
  boolean: "Boolean",
};

const NAMED = Symbol.for("envio.resolvers.graphqlType");

// `S.bigint` and `S.bigDecimal` are transformed strings, so the tag walk below
// would call them String -- turning a 30-digit PnL figure into an untyped one
// in the published schema. They are the vocabulary handlers already write in,
// so they get their scalars without the user naming them again.
const ENVIO_SCALARS = new Map([
  [UtilsBigInt.schema, "BigInt"],
  [bigDecimalSchema, "BigDecimal"],
]);

// Tagging is never applied to the caller's schema object. `S.string` and
// friends are shared singletons, so `defineScalar("BigInt", S.string)` would
// otherwise rename every string in the project to BigInt. Cloning keeps the
// tag local to the declaration.
function tagged(schema, named) {
  const copy = Object.create(Object.getPrototypeOf(schema));
  Object.assign(copy, schema);
  copy[NAMED] = named;
  return copy;
}

// S.name throws on some schema shapes, and this only ever runs while
// building an error message -- a failure here would replace a useful message
// with a confusing one.
function describe(schema) {
  try {
    return S.name(schema);
  } catch {
    return JSON.stringify(schema?.t) ?? "unknown";
  }
}

/** Names a schema so it can appear in the GraphQL schema. */
export function defineType(name, fields) {
  if (!GQL_NAME.test(name)) {
    throw new Error(
      `Invalid GraphQL type name '${name}': must match ${GQL_NAME.source}`
    );
  }
  // S.schema() mutates the object it is given, replacing each schema value
  // in place, so the field map has to be snapshotted before handing it over
  // or the GraphQL walk below finds gutted entries.
  const declared = { ...fields };
  return tagged(S.schema(fields), { name, fields: declared });
}

/**
 * Names a schema that appears in an argument.
 *
 * GraphQL keeps input and output types in separate namespaces: a `where`
 * argument is an `input`, and an object type declared with defineType cannot
 * stand in for one.
 */
export function defineInput(name, fields) {
  if (!GQL_NAME.test(name)) {
    throw new Error(
      `Invalid GraphQL input type name '${name}': must match ${GQL_NAME.source}`
    );
  }
  const declared = { ...fields };
  return tagged(S.schema(fields), { name, fields: declared, input: true });
}

/** Names a schema representing a GraphQL enum. */
export function defineEnum(name, values) {
  if (!GQL_NAME.test(name)) {
    throw new Error(
      `Invalid GraphQL enum name '${name}': must match ${GQL_NAME.source}`
    );
  }
  if (!Array.isArray(values) || values.length === 0) {
    throw new Error(`Enum '${name}' must declare at least one value`);
  }
  for (const v of values) {
    if (!GQL_NAME.test(v)) {
      throw new Error(`Invalid enum value '${v}' on '${name}'`);
    }
  }
  return tagged(S.union(values.map((v) => S.schema(v))), {
    name,
    enumValues: values,
  });
}

/** Names a schema representing a custom GraphQL scalar. */
export function defineScalar(name, schema) {
  if (!GQL_NAME.test(name)) {
    throw new Error(`Invalid GraphQL scalar name '${name}'`);
  }
  return tagged(schema, { name, scalar: true });
}

/**
 * A root-level optional, unwrapped.
 *
 * `undefined` has no JSON form, so Sury refuses to convert an `S.optional(x)`
 * at the root at all — not just when the value is absent. A resolver
 * declaring a nullable result is the ordinary case (nothing found, or a
 * failure that shouldn't take the rest of the operation down), so the absent
 * value becomes `null` on the wire and a present one converts through the
 * inner schema. Optionals *inside* an object are untouched: Sury omits those
 * fields, which is what GraphQL wants.
 */
export function unwrapNullableOutput(schema) {
  const tag = tagOf(schema);
  if (tag.kind === "option" || tag.kind === "null") {
    return { inner: tag.node._0, nullable: true };
  }
  return { inner: schema, nullable: false };
}

function tagOf(schema) {
  const t = schema.t;
  if (typeof t === "string") return { kind: t };
  if (t && typeof t === "object" && t.TAG) return { kind: t.TAG, node: t };
  return { kind: "unknown" };
}

/**
 * Walks a schema into a GraphQL type string, registering any named composite
 * types it encounters into `types`.
 *
 * Nullability is inverted relative to Sury: a GraphQL field is non-null
 * unless the schema is optional, which matches how both systems are read in
 * practice — `S.string` means "a string", `S.optional(S.string)` means "or
 * absent".
 */
export function toGraphQLType(schema, types, path, position = "output") {
  const tag = tagOf(schema);

  if (tag.kind === "option" || tag.kind === "null") {
    // Already nullable: unwrap without adding `!`.
    return nullableOf(tag.node._0, types, path);
  }
  return `${nullableOf(schema, types, path)}!`;

  function nullableOf(inner, types, path) {
    const innerNamed = inner[NAMED];
    const innerTag = tagOf(inner);

    if (innerTag.kind === "option" || innerTag.kind === "null") {
      // `S.optional(S.optional(x))` — collapse; GraphQL has one null.
      return nullableOf(innerTag.node._0, types, path);
    }
    if (innerNamed) {
      register(inner, innerNamed, types, path, position);
      return innerNamed.name;
    }
    // After the explicit name, so `defineScalar` on a clone still wins.
    const envioScalar = ENVIO_SCALARS.get(inner);
    if (envioScalar !== undefined) {
      register(inner, { name: envioScalar, scalar: true }, types, path, position);
      return envioScalar;
    }
    if (innerTag.kind === "array") {
      return `[${toGraphQLType(innerTag.node._0, types, `${path}[]`, position)}]`;
    }
    const builtin = BUILTIN_SCALARS[innerTag.kind];
    if (builtin) return builtin;

    if (innerTag.kind === "object") {
      const define = position === "input" ? "defineInput" : "defineType";
      throw new Error(
        `${path}: object types must be named. Wrap it in ${define}("SomeName", {...}) — ` +
          `GraphQL has no anonymous types, and a generated name would leak into your public API.`
      );
    }
    throw new Error(
      `${path}: unsupported schema '${describe(inner)}'. Supported: string, int32, number, ` +
        `boolean, arrays, optionals, and schemas named with defineType / defineInput / ` +
        `defineEnum / defineScalar.`
    );
  }
}

function register(schema, named, types, path, position) {
  // Checked before the registration below returns early, so a type reused in
  // the wrong position is caught even when it is already registered from the
  // right one. Scalars and enums are legal in both.
  if (named.fields) {
    if (named.input && position === "output") {
      throw new Error(
        `${path}: '${named.name}' is an input object and cannot appear in a result. ` +
          `Declare the result's type with defineType("${named.name}Result", {...}).`
      );
    }
    if (!named.input && position === "input") {
      throw new Error(
        `${path}: '${named.name}' is an object type and cannot be an argument. ` +
          `Declare it with defineInput("${named.name}Input", {...}) — GraphQL keeps input ` +
          `and output types in separate namespaces.`
      );
    }
  }

  const existing = types.get(named.name);
  if (existing) {
    // The same declaration used twice is fine; two different ones sharing a
    // name is a collision the user has to resolve, and saying so here beats
    // serve rejecting the manifest later with less context.
    if (existing.schema !== schema) {
      throw new Error(
        `${path}: two different types are both named '${named.name}'`
      );
    }
    return;
  }
  // Reserve the name before walking fields so a self-referential type
  // terminates instead of recursing forever.
  const entry = { schema, def: null };
  types.set(named.name, entry);

  if (named.scalar) {
    entry.def = { kind: "scalar", name: named.name };
    return;
  }
  if (named.enumValues) {
    entry.def = {
      kind: "enum",
      name: named.name,
      values: named.enumValues.map((v) => ({ name: v })),
    };
    return;
  }
  entry.def = {
    kind: named.input ? "input_object" : "object",
    name: named.name,
    fields: Object.entries(named.fields).map(([fieldName, fieldSchema]) => {
      if (!GQL_NAME.test(fieldName)) {
        throw new Error(`Invalid field name '${named.name}.${fieldName}'`);
      }
      return {
        name: fieldName,
        type: toGraphQLType(
          fieldSchema,
          types,
          `${named.name}.${fieldName}`,
          named.input ? "input" : "output"
        ),
      };
    }),
  };
}

/** Builds the manifest for a set of resolver declarations. */
export function buildManifest(resolvers) {
  const types = new Map();
  const seen = new Set();
  const entries = [];

  for (const resolver of resolvers) {
    const { name } = resolver;
    if (!GQL_NAME.test(name)) {
      throw new Error(`Invalid resolver name '${name}'`);
    }
    if (name.startsWith("__")) {
      throw new Error(
        `Resolver '${name}' uses the reserved '__' prefix, which GraphQL introspection owns`
      );
    }
    if (seen.has(name)) {
      throw new Error(`Duplicate resolver '${name}'`);
    }
    seen.add(name);
    // Refused rather than ignored. It was carried through the manifest and read
    // by nothing, so a resolver author could set it, see no error, and believe
    // an expensive query was being cached.
    if (resolver.cacheTtlMs !== undefined) {
      throw new Error(
        `Resolver '${name}' sets cacheTtlMs, which is not implemented -- nothing caches resolver ` +
          `responses today. Remove it; it would otherwise read as caching that is not happening.`
      );
    }
    if (!resolver.timeoutMs || resolver.timeoutMs <= 0) {
      throw new Error(
        `Resolver '${name}' must set a positive timeoutMs. It becomes the statement_timeout on every query the resolver makes, which is the only thing bounding a runaway one.`
      );
    }

    entries.push({
      name,
      ...(resolver.description ? { description: resolver.description } : {}),
      args: Object.entries(resolver.args ?? {}).map(([argName, argSchema]) => {
        if (!GQL_NAME.test(argName)) {
          throw new Error(`Invalid argument name '${name}.${argName}'`);
        }
        return {
          name: argName,
          type: toGraphQLType(argSchema, types, `${name}.${argName}`, "input"),
        };
      }),
      type: toGraphQLType(resolver.output, types, `${name} result`),
      admin: resolver.admin === true,
      timeoutMs: resolver.timeoutMs,
    });
  }

  return {
    schemaVersion: SCHEMA_VERSION,
    resolvers: entries,
    // Sorted so the manifest is stable across runs: it is written into the
    // image and diffed, and Map order would otherwise depend on declaration
    // order across files.
    types: [...types.values()]
      .map((e) => e.def)
      .sort((a, b) => a.name.localeCompare(b.name)),
  };
}

/** Renders the manifest as SDL, for humans and for `envio dev` to diff. */
export function toSDL(manifest) {
  const lines = [];
  for (const type of manifest.types) {
    if (type.kind === "scalar") {
      lines.push(`scalar ${type.name}`, "");
    } else if (type.kind === "enum") {
      lines.push(`enum ${type.name} {`);
      for (const v of type.values) lines.push(`  ${v.name}`);
      lines.push("}", "");
    } else {
      lines.push(`${type.kind === "input_object" ? "input" : "type"} ${type.name} {`);
      for (const f of type.fields) lines.push(`  ${f.name}: ${f.type}`);
      lines.push("}", "");
    }
  }
  // A project with no resolvers gets no Query extension at all: an empty
  // `extend type Query { }` block is not valid SDL.
  if (manifest.resolvers.length === 0) {
    return lines.join("\n");
  }
  lines.push("extend type Query {");
  for (const r of manifest.resolvers) {
    const args = r.args.length
      ? `(${r.args.map((a) => `${a.name}: ${a.type}`).join(", ")})`
      : "";
    lines.push(`  ${r.name}${args}: ${r.type}`);
  }
  lines.push("}", "");
  return lines.join("\n");
}
