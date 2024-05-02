// In postgres floats are stored as numeric, which get returned to us as strtings. So the decoder / encoder need to do that for us.
module Float = {
  @genType
  type t = float

  let t_encode = (t_value: t) => t_value->Js.Float.toString->Js.Json.string

  let t_decode: Js.Json.t => result<t, Spice.decodeError> = json =>
    switch json->Js.Json.decodeString {
    | Some(stringDbFloat) =>
      switch stringDbFloat->Belt.Float.fromString {
      | Some(db) => Ok(db)
      | None =>
        let spiceErr: Spice.decodeError = {
          path: "GqlDbCustomTypes.Float.t",
          message: "String not deserializeable to GqlDbCustomTypes.Float.t",
          value: json,
        }
        Error(spiceErr)
      }
    | None =>
      let spiceErr: Spice.decodeError = {
        path: "GqlDbCustomTypes.Float.t",
        message: "Json not deserializeable to string of GqlDbCustomTypes.Float.t",
        value: json,
      }
      Error(spiceErr)
    }

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
