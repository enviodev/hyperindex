@module("fs") @module("js-yaml") external loadYaml: string => 'yamlData = "load"

exception ConfigFileNotFound(string)

let loadConfigYaml = (~codegenConfigPath: string) => {
  try {
    let configString =
      NodeJs.Fs.readFileSyncWith(codegenConfigPath, {encoding: "utf8"})->NodeJs.Buffer.toString

    let yamlData = loadYaml(configString)

    yamlData
  } catch {
  | Js.Exn.Error(obj) => {
      switch Js.Exn.message(obj) {
      | Some(m) => raise(ConfigFileNotFound("config file not found: " ++ m))
      | None => ()
      }
      Utils.magic()
    }
  }
}
