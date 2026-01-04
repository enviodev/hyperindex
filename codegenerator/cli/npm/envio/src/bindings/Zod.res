// ReScript bindings for Zod (v4 API compatible with v3.25+)

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
