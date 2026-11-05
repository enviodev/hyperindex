// Short enough that a chain at the head is not held up behind it, long enough
// that a wait polling through a whole block interval is not thousands of
// requests.
let pollingInterval = 400

let requireApiToken = apiToken =>
  switch apiToken {
  | Some(token) => token
  | None =>
    JsError.throwWithMessage(`An Envio API token is required for using HyperSync as a data-source.
Set the ENVIO_API_TOKEN environment variable in your .env file.
Learn more or get a free Envio API token at: https://envio.dev/app/api-tokens`)
  }
