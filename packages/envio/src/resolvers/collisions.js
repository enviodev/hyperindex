// Names envio-serve derives from schema.graphql, which a custom resolver must
// not squat.
//
// This mirrors the builder in envio-serve's `gql/schema_build.rs`: the two are
// one contract, and drift shows up as a schema serve refuses to start on.
// Serve does re-check at startup, deliberately -- but by then the user is
// reading a deployment log, and the build is where they can act. Hence both,
// as §6.1 asks.
//
// Not covered here: the `<scalar>_comparison_exp` types serve derives from
// column types. Mapping an entity field's type to serve's scalar name is not
// something this side can do without guessing, and serve's own check is the
// backstop for it.

const ROOT_AND_BUILTIN_TYPES = [
  "query_root",
  "subscription_root",
  "order_by",
  "cursor_ordering",
  "Boolean",
  "Float",
  "Int",
  "String",
];

const rootFieldsOf = (entity) => [
  [entity, `entity '${entity}'`],
  [`${entity}_by_pk`, `the by-primary-key field of entity '${entity}'`],
  [`${entity}_aggregate`, `the aggregate field of entity '${entity}'`],
  [`${entity}_stream`, `the subscription stream of entity '${entity}'`],
];

const typesOf = (entity) =>
  [
    "",
    "_aggregate",
    "_aggregate_bool_exp",
    "_aggregate_bool_exp_count",
    "_aggregate_fields",
    "_aggregate_order_by",
    "_bool_exp",
    "_order_by",
    "_select_column",
    "_stream_cursor_input",
    "_stream_cursor_value_input",
  ].map((suffix) => [
    `${entity}${suffix}`,
    suffix === ""
      ? `the row type of entity '${entity}'`
      : `a type generated for entity '${entity}'`,
  ]);

/** Every generated name, mapped to how it would read in an error. */
export function reservedNames({ entities = [], enums = [] }) {
  const rootFields = new Map();
  const types = new Map();

  for (const [name, describe] of ROOT_AND_BUILTIN_TYPES.map((name) => [
    name,
    "a built-in GraphQL type name",
  ])) {
    types.set(name, describe);
  }
  for (const name of enums) {
    types.set(name, "an enum declared in schema.graphql");
  }
  for (const entity of entities) {
    for (const [name, describe] of rootFieldsOf(entity)) {
      rootFields.set(name, describe);
    }
    for (const [name, describe] of typesOf(entity)) {
      types.set(name, describe);
    }
  }
  return { rootFields, types };
}

/**
 * Throws when a manifest declares a root field or type name envio-serve
 * generates. Reports all of them at once: renaming one at a time through a
 * build each is the slow way to find out there were three.
 */
export function checkCollisions(manifest, { entities, enums }) {
  const reserved = reservedNames({ entities, enums });
  const found = [];

  for (const resolver of manifest.resolvers) {
    const describe = reserved.rootFields.get(resolver.name);
    if (describe !== undefined) {
      found.push(`  - resolver '${resolver.name}' is ${describe}`);
    }
  }
  for (const type of manifest.types) {
    const describe = reserved.types.get(type.name);
    if (describe !== undefined) {
      found.push(`  - type '${type.name}' is ${describe}`);
    }
  }

  if (found.length > 0) {
    throw new Error(
      `Custom resolvers collide with names envio-serve generates from schema.graphql:\n${found.join(
        "\n"
      )}\nRename them: envio-serve owns those names and refuses to start on an ambiguous schema.`
    );
  }
}
