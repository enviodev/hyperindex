// In postgres floats are stored as numeric, which get returned to us as strtings. So the decoder / encoder need to do that for us.
module Float = {
  type dbNumericFloat = float

  let dbNumericFloat_encode = (dbNumericFloat_value: dbNumericFloat) =>
    dbNumericFloat_value->Js.Float.toString->Js.Json.string

  let dbNumericFloat_decode: Js.Json.t => result<dbNumericFloat, Spice.decodeError> = json =>
    switch json->Js.Json.decodeString {
    | Some(stringDbFloat) =>
      switch stringDbFloat->Belt.Float.fromString {
      | Some(db) => Ok(db)
      | None =>
        let spiceErr: Spice.decodeError = {
          path: "dbNumericFloat",
          message: "String not deserializeable to dbNumericFloat",
          value: json,
        }
        Error(spiceErr)
      }
    | None =>
      let spiceErr: Spice.decodeError = {
        path: "dbNumericFloat",
        message: "Json not deserializeable to string of dbNumericFloat",
        value: json,
      }
      Error(spiceErr)
    }
}
