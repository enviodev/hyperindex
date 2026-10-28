// Values as the addon declares each staged field has to arrive, compiled once
// per layout and written into a stage.

@send external getTime: unknown => float = "getTime"
@send external toFixed: unknown => string = "toFixed"
@val @scope("Array") external isArray: unknown => bool = "isArray"

// A list element as its JSON: the encoding a scalar of its type would take,
// except that a boolean stays one and bytes become their values.
%%private(
  let elementOf = (encoding: Staging.encoding, ~column): (unknown => unknown) =>
    switch encoding {
    | Number =>
      value =>
        value->Staging.toNumber->Staging.finiteOrThrow(~column)->(Utils.magic: float => unknown)
    | Date => value => value->getTime->(Utils.magic: float => unknown)
    | Digits => value => value->Staging.stringOf->(Utils.magic: string => unknown)
    | Decimal => value => value->toFixed->(Utils.magic: string => unknown)
    | Document => value => value->Sql.canonicalDocument->(Utils.magic: string => unknown)
    | Bytes =>
      value =>
        value
        ->(Utils.magic: unknown => Array.arrayLike<int>)
        ->Array.fromArrayLike
        ->(Utils.magic: array<int> => unknown)
    | Bool | Text | List => value => value
    }
)

%%private(
  let rec mapList = (value: unknown, element: unknown => unknown): unknown =>
    if value->isArray {
      value
      ->(Utils.magic: unknown => array<unknown>)
      ->Array.map(item => item->mapList(element))
      ->(Utils.magic: array<unknown> => unknown)
    } else if value === %raw(`undefined`) || value === %raw(`null`) {
      %raw(`null`)
    } else {
      element(value)
    }
)

// What a present value becomes before it is written to its slot.
%%private(
  let encoderOf = ({name, encoding, element}: Staging.stagedField): (unknown => unknown) =>
    switch encoding {
    | Bool =>
      value => (value->(Utils.magic: unknown => bool) ? 1. : 0.)->(Utils.magic: float => unknown)
    | Date => value => value->getTime->(Utils.magic: float => unknown)
    | Decimal => value => value->toFixed->(Utils.magic: string => unknown)
    | Document => value => value->Sql.canonicalDocument->(Utils.magic: string => unknown)
    | List =>
      let encode = elementOf(element, ~column=name)
      // A document can be a list itself, so a list of them is one level deep.
      let mapList = switch element {
      | Document =>
        (value, encode) =>
          value
          ->(Utils.magic: unknown => array<unknown>)
          ->Array.map(item => item->Staging.isAbsent ? %raw(`null`) : encode(item))
          ->(Utils.magic: array<unknown> => unknown)
      | _ => mapList
      }
      value =>
        value
        ->mapList(encode)
        ->(Utils.magic: unknown => JSON.t)
        ->JSON.stringify
        ->Utils.replaceLoneSurrogateEscapes
        ->(Utils.magic: string => unknown)
    | Number | Text | Digits | Bytes => value => value
    }
)

// A layout's fields compiled once: the slot each takes and how a value of it
// is written there.
type writer = {field: Staging.stagedField, encode: unknown => unknown}

let writersOf = (fields: array<Staging.stagedField>) =>
  fields->Array.map(field => {field, encode: encoderOf(field)})

let columnsOf = (writers: array<writer>): array<Staging.column> =>
  writers->Array.map(({field}) => {
    Staging.name: field.name,
    kind: field.encoding->Staging.kindOf,
    isNullable: field.isNullable,
  })

// A document always says something: one the handler left out of a column
// that can't be NULL is the document `null`.
let writeField = (stage, ~writers: array<writer>, ~column, ~row, value: unknown) => {
  let {field, encode} = writers->Array.getUnsafe(column)
  if value->Staging.isAbsent {
    stage->Staging.writeValue(
      ~column,
      ~row,
      field.encoding === Staging.Document && !field.isNullable
        ? "null"->(Utils.magic: string => unknown)
        : value,
    )
  } else {
    stage->Staging.writeValue(~column, ~row, encode(value))
  }
}
