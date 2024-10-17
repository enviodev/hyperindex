exception FailedToFetch(exn)
exception FailedToParseJson(exn)

type queryError =
  | Deserialize(Js.Json.t, S.error)
  | FailedToFetch(exn)
  | FailedToParseJson(exn)
  | Other(exn)

let executeFetchRequest = async (
  ~endpoint,
  ~method: Fetch.method,
  ~bodyAndSchema: option<('body, S.t<'body>)>=?,
  ~responseSchema: S.t<'data>,
): result<'data, queryError> => {
  try {
    open Fetch

    let body = bodyAndSchema->Belt.Option.map(((body, schema)) => {
      body->S.reverseConvertToJsonStringWith(schema)->Body.string
    })

    let res =
      await fetch(
        endpoint,
        {method, headers: Headers.fromObject({"Content-type": "application/json"}), ?body},
      )->Promise.catch(e => Promise.reject(FailedToFetch(e)))

    let data = await res->Response.json->Promise.catch(e => Promise.reject(FailedToParseJson(e)))

    switch data->S.parseWith(responseSchema) {
    | Ok(_) as ok => ok
    | Error(e) => Error(Deserialize(data, e))
    }
  } catch {
  | FailedToFetch(exn) => Error(FailedToFetch(exn))
  | FailedToParseJson(exn) => Error(FailedToParseJson(exn))
  | exn => Error(Other(exn))
  }
}
