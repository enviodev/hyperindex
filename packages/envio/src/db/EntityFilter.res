// The And case requires at least one nested filter (storage throws otherwise),
// while In with an empty array matches nothing.
@tag("operator")
type rec t =
  | @as("=") Eq({fieldName: string, fieldValue: unknown})
  | @as(">") Gt({fieldName: string, fieldValue: unknown})
  | @as("<") Lt({fieldName: string, fieldValue: unknown})
  | @as("in") In({fieldName: string, fieldValue: array<unknown>})
  | @as("and") And({filters: array<t>})
