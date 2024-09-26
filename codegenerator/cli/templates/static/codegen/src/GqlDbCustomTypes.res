// In postgres floats are stored as numeric, which get returned to us as strtings. So the decoder / encoder need to do that for us.
module Float = {
  @genType
  type t = float

  let schema =
    S.string
    ->S.setName("GqlDbCustomTypes.Float")
    ->S.transform(s => {
      parser: string => {
        switch string->Belt.Float.fromString {
        | Some(db) => db
        | None => s.fail("The string is not valid GqlDbCustomTypes.Float")
        }
      },
      serializer: float => float->Js.Float.toString,
    })
}

// Schema allows parsing strings or numbers to ints
// this is needed for entity_history field where we on the first copy we encode all numbers as strings
// to avoid loss of precision. Otherwise we always serialize to int
module Int = {
  @genType
  type t = int

  external number: unknown => Js.Json.t = "Number"

  let schema = S.custom("GqlDbCustomTypes.Int", _ => {
    parser: unknown => {
      unknown->number->S.parseOrRaiseWith(S.int)
    },
    serializer: int => int,
  })
}
