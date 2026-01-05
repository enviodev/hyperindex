// ReScript bindings for Zod (v4 API compatible with v3.25+)
//
// Zod is used by the MCP Server for input schema validation.
// It's declared as a peer dependency of @modelcontextprotocol/sdk and is
// explicitly added to package.json.hbs (version: ^3.25.0) to ensure it's
// available at runtime. This satisfies the MCP SDK peer dependency requirement
// of ^3.25 || ^4.0

type zodSchema<'a>

// Basic types
@module("zod/v4") @scope("z")
external string: unit => zodSchema<string> = "string"

@module("zod/v4") @scope("z")
external number: unit => zodSchema<float> = "number"

@module("zod/v4") @scope("z")
external boolean: unit => zodSchema<bool> = "boolean"

@module("zod/v4") @scope("z")
external object: Js.Dict.t<zodSchema<'a>> => zodSchema<Js.Dict.t<'a>> = "object"

// Modifiers
@send
external optional: zodSchema<'a> => zodSchema<option<'a>> = "optional"

@send
external describe: (zodSchema<'a>, string) => zodSchema<'a> = "describe"
