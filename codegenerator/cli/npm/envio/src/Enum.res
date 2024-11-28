// Graphql Enum Type Variants
type enum<'a> = {
  name: string,
  variants: array<'a>,
  schema: S.t<'a>,
  default: 'a,
}

let make = (~name, ~variants) => {
  name,
  variants,
  schema: S.enum(variants),
  default: switch variants->Belt.Array.get(0) {
  | Some(v) => v
  | None => Js.Exn.raiseError("No variants defined for enum " ++ name)
  },
}

module type S = {
  type t
  let enum: enum<t>
}
