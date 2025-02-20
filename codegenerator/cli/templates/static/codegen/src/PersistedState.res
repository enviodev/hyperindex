type t = {
  @as("envio_version") envioVersion: string,
  @as("config_hash") configHash: string,
  @as("schema_hash") schemaHash: string,
  @as("handler_files_hash") handlerFilesHash: string,
  @as("abi_files_hash") abiFilesHash: string,
}

let schema = S.schema(s => {
  envioVersion: s.matches(S.string),
  configHash: s.matches(S.string),
  schemaHash: s.matches(S.string),
  handlerFilesHash: s.matches(S.string),
  abiFilesHash: s.matches(S.string),
})

external requireJson: string => Js.Json.t = "require"
let getPersistedState = () =>
  try {
    let json = requireJson("../persisted_state.envio.json")
    let parsed = json->S.parseJsonOrThrow(schema)
    Ok(parsed)
  } catch {
  | exn => Error(exn)
  }
