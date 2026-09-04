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

/** The header Hasura presents so the handler can tell it apart from anyone
 *  else who can reach the socket. */
export const RESOLVER_SECRET_HEADER = "x-envio-resolver-secret";

/** Where a caller presents the key that unlocks a `private` resolver. */
export const PRIVATE_KEY_HEADER = "x-envio-private-key";

/**
 * @param manifest the parsed `.envio/resolvers.json`
 * @param handlerUrl the URL *Hasura* posts to -- reachable from Hasura, which
 *   is not necessarily the address the service binds
 * @param publicRole the role a non-admin caller runs as (Hasura's
 *   `unauthorized_role`)
 */
export function buildHasuraMetadata(manifest, { handlerUrl, publicRole = "public", actionSecret }) {
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
      // Hasura's timeout is whole seconds and bounds the whole HTTP call; the
      // resolver's own `timeoutMs` bounds only the queries inside it. Acquiring
      // a connection, parsing arguments and serializing the result spend
      // Hasura's budget without spending the resolver's, so the extra second is
      // what keeps Hasura from being the first to give up on a request the
      // resolver still considers live -- which the client would see as an
      // unreachable webhook rather than as a timeout.
      timeout: Math.ceil(resolver.timeoutMs / 1000) + 1,
      // The role reaches the handler inside the request body, so on its own it
      // is the caller's claim rather than a fact. This header is the only thing
      // that makes it one: Hasura sends it because the action declares it, and
      // the value is literal, so Hasura itself needs no configuration.
      ...(actionSecret
        ? { headers: [{ name: RESOLVER_SECRET_HEADER, value: actionSecret }] }
        : {}),
      // A private resolver authenticates its caller here, not at Hasura, so
      // the caller's own headers have to survive the hop. Hasura's static
      // `headers` above still win on a name clash, so this cannot be used to
      // spoof the shared secret.
      ...(resolver.private ? { forward_client_headers: true } : {}),
    };
    const action = { name: resolver.name, definition };
    if (resolver.description) {
      action.comment = resolver.description;
    }
    actions.push(action);

    // Every resolver is granted to the public role, private ones included:
    // without the permission Hasura refuses to route the call at all, and then
    // there is nothing for the key check to run against. Being routable is not
    // being reachable -- a private resolver still refuses anyone who cannot
    // present a key.
    permissions.push({ action: resolver.name, role: publicRole });
  }

  return {
    customTypes: { scalars, enums, input_objects: inputObjects, objects },
    actions,
    permissions,
  };
}
