// In postgres floats are stored as numeric, which get returned to us as strtings. So the decoder / encoder need to do that for us.
module Float = {
  @genType
  type t = float

  let schema =
    S.string
    ->S.setName("GqlDbCustomTypes.Float")
    ->S.transform((. s) => {
      parser: (. string) => {
        switch string->Belt.Float.fromString {
        | Some(db) => db
        | None => s.fail(. "The string is not valid GqlDbCustomTypes.Float")
        }
      },
      serializer: (. float) => float->Js.Float.toString,
    })
}
