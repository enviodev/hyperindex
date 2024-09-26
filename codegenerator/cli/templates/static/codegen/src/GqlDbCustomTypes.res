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

  external fromStringUnsafe: string => int = "Number"

  let schema =
    S.union([
      S.int,
      S.string->S.transform(_s => {parser: string => string->fromStringUnsafe}),
    ])->S.setName("GqlDbCustomTypes.Int")
}
