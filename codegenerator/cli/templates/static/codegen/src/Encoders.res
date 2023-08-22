
module Nullable = {
  type t<'a> = option<'a>

  let t_encode = Spice.optionToJson
  let t_decode: (Js.Json.t => Belt.Result.t<'a, 'b>, Js.Json.t) => Belt.Result.t<option<'a>, 'b> = (
    innerDecoder,
    json,
  ) => {
    switch json->Js.Json.decodeNull {
    | Some(_) => Ok(None)
    | None => json->innerDecoder->Belt.Result.map(decoded => Some(decoded))
    }
  }
}
