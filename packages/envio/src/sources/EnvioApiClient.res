// Rest client for envio's own REST endpoints (e.g. the HyperSync/HyperFuel
// /height poll). Tags requests with the hyperindex User-Agent so they're
// attributable on the server, mirroring the SSE height stream and the Rust
// data-query client which already set it.
let make = (baseUrl: string): Rest.client => {
  let userAgent = `hyperindex/${Utils.EnvioPackage.value.version}`
  Rest.client(baseUrl, ~fetcher=(args: Rest.ApiFetcher.args) => {
    let headers = switch args.headers {
    | Some(headers) => headers
    | None => Dict.make()
    }
    headers->Dict.set("User-Agent", userAgent->(Utils.magic: string => unknown))
    Rest.ApiFetcher.default({...args, headers: Some(headers)})
  })
}
