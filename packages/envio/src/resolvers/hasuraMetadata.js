// The manifest, expressed as the Hasura metadata that makes each resolver a
// queryable root field.
//
// Hasura cannot execute user code, so an action is a declaration: the field's
// name, its arguments, its result type, and a URL to POST to. Everything here
// is derived from the manifest `envio codegen` already writes, so the schema
// Hasura publishes and the code that answers it come from one source.
//
// Pure on purpose -- manifest in, JSON out, no network. Applying it is
// `hasuraApply.js`; keeping the two apart is what makes the shape testable
// without a Hasura to point at.

// Hasura's own; anything else a resolver names has to be declared.
const BUILTIN_SCALARS = new Set(["String", "Int", "Float", "Boolean", "ID"]);

/**
 * @param manifest the parsed `.envio/resolvers.json`
 * @param handlerUrl the URL *Hasura* posts to -- reachable from Hasura, which
 *   is not necessarily the address the service binds
 * @param publicRole the role a non-admin caller runs as (Hasura's
 *   `unauthorized_role`)
 */
export function buildHasuraMetadata(manifest, { handlerUrl, publicRole = "public" }) {
  if (!handlerUrl) {
    throw new Error(
      "buildHasuraMetadata requires a handlerUrl: it is baked into every action, and Hasura has no other way to reach the resolvers."
    );
  }

  const scalars = [];
  const enums = [];
  const objects = [];
  const inputObjects = [];

  for (const type of manifest.types ?? []) {
    switch (type.kind) {
      case "scalar":
        // A resolver declaring `String` as a custom scalar would shadow
        // Hasura's own and make the metadata inconsistent.
        if (BUILTIN_SCALARS.has(type.name)) {
          throw new Error(
            `Custom scalar '${type.name}' collides with a GraphQL built-in scalar.`
          );
        }
        scalars.push({ name: type.name });
        break;
      case "enum":
        enums.push({
          name: type.name,
          // The manifest names an enum value `name`; Hasura calls it `value`.
          values: type.values.map(({ name }) => ({ value: name })),
        });
        break;
      case "object":
        objects.push({ name: type.name, fields: type.fields });
        break;
      case "input_object":
        inputObjects.push({ name: type.name, fields: type.fields });
        break;
      default:
        // Emitting a partial set would leave Hasura with an action whose types
        // are missing, which fails at apply time with a worse message than this.
        throw new Error(
          `Cannot express manifest type '${type.name}' of kind '${type.kind}' as a Hasura custom type.`
        );
    }
  }

  const actions = [];
  const permissions = [];

  for (const resolver of manifest.resolvers ?? []) {
    const definition = {
      // An action is a mutation unless it says otherwise, and a resolver is a
      // read: the manifest's own SDL says `extend type Query`.
      type: "query",
      kind: "synchronous",
      handler: handlerUrl,
      arguments: resolver.args ?? [],
      output_type: resolver.type,
      // Hasura's timeout is whole seconds and bounds the HTTP call; the
      // resolver's own `timeoutMs` bounds its queries. Rounded up so Hasura is
      // never the first to give up on a request the resolver still considers
      // live.
      timeout: Math.max(1, Math.ceil(resolver.timeoutMs / 1000)),
    };
    const action = { name: resolver.name, definition };
    if (resolver.description) {
      action.comment = resolver.description;
    }
    actions.push(action);

    // Admin has access to everything in Hasura by definition, so an admin-only
    // resolver is one with no public permission -- there is nothing to grant.
    if (!resolver.admin) {
      permissions.push({ action: resolver.name, role: publicRole });
    }
  }

  return {
    customTypes: { scalars, enums, input_objects: inputObjects, objects },
    actions,
    permissions,
  };
}
