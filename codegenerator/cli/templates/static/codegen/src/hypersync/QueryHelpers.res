exception FailedToFetch(exn)
exception FailedToParseJson(exn)

type queryError =
  Deserialize(Spice.decodeError) | FailedToFetch(exn) | FailedToParseJson(exn) | Other(exn)

let executeFetchRequest = async (
  ~endpoint,
  ~method: Fetch.method,
  ~bodyAndEncoder: option<('a, 'a => Js.Json.t)>=?,
  ~responseDecoder: Spice.decoder<'b>,
  (),
): result<'b, queryError> => {
  try {
    open Fetch

    let body = bodyAndEncoder->Belt.Option.map(((body, encoder)) => {
      body->encoder->Js.Json.stringify->Body.string
    })

    let res =
      await fetch(
        endpoint,
        {method, headers: Headers.fromObject({"Content-type": "application/json"}), ?body},
      )->Promise.catch(e => Promise.reject(FailedToFetch(e)))

    let data = await res->Response.json->Promise.catch(e => Promise.reject(FailedToParseJson(e)))

    switch data->responseDecoder {
    | Error(e) => Error(Deserialize(e))
    | Ok(v) => Ok(v)
    }
  } catch {
  | FailedToFetch(exn) => Error(FailedToFetch(exn))
  | FailedToParseJson(exn) => Error(FailedToParseJson(exn))
  | exn => Error(Other(exn))
  }
}
