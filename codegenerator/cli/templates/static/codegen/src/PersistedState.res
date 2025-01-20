type t = {
  @as("envio_version") envioVersion: string,
  @as("config_hash") configHash: string,
  @as("schema_hash") schemaHash: string,
  @as("handler_files_hash") handlerFilesHash: string,
  @as("abi_files_hash") abiFilesHash: string,
}

let schema: S.t<t> = S.object(s => {
  envioVersion: s.field("envio_version", S.string),
  configHash: s.field("config_hash", S.string),
  schemaHash: s.field("schema_hash", S.string),
  handlerFilesHash: s.field("handler_files_hash", S.string),
  abiFilesHash: s.field("abi_files_hash", S.string),
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
