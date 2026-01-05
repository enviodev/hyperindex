// ReScript bindings for Zod (v4 API compatible with v3.25+)
//
// Zod is used by the MCP Server for input schema validation.
// It's declared as a peer dependency of @modelcontextprotocol/sdk and is
// explicitly pinned to version 3.25.76 in package.json.hbs for reproducibility.
// This satisfies the MCP SDK peer dependency requirement of ^3.25 || ^4.0

type zodSchema<'a>

// Basic types
@module("zod/v4") @scope("z")
external string: unit => zodSchema<string> = "string"

@module("zod/v4") @scope("z")
external number: unit => zodSchema<float> = "number"

@module("zod/v4") @scope("z")
external boolean: unit => zodSchema<bool> = "boolean"

@module("zod/v4") @scope("z")
external array: zodSchema<'a> => zodSchema<array<'a>> = "array"

@module("zod/v4") @scope("z")
external object: Js.Dict.t<zodSchema<'a>> => zodSchema<Js.Dict.t<'a>> = "object"

// Modifiers
@send
external optional: zodSchema<'a> => zodSchema<option<'a>> = "optional"

@send
external describe: (zodSchema<'a>, string) => zodSchema<'a> = "describe"
