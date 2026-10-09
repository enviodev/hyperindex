// `entity_filter::Condition` in packages/cli/src/entity_filter.rs, which every
// storage answers with a statement of its own. The column is in the receiving
// storage's own naming; the values are spelled as `valueKind` says, never in
// one storage's syntax.

type operator =
  | @as("Eq") Eq
  | @as("Gt") Gt
  | @as("Lt") Lt
  | @as("Gte") Gte
  | @as("Lte") Lte
  | @as("In") In

type valueKind =
  | @as("Text") Text
  | @as("Boolean") Boolean
  | @as("Number") Number
  | @as("Timestamp") Timestamp
  | @as("Bytes") Bytes
  | @as("Json") Json
  | @as("Enum") Enum

type t = {
  column: string,
  operator: operator,
  values: array<array<Null.t<string>>>,
  kind: valueKind,
  isList: bool,
  enumName?: string,
  isChainId: bool,
}
