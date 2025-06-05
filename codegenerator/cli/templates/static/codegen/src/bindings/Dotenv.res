type config = {path?: string}
type envRes

@module("dotenv") external config: config => envRes = "config"

module Utils = {
  type require = {resolve: string => string}
  external require: require = "require"

  let getEnvFilePath = () =>
    switch require.resolve(`../../${Path.relativePathToRootFromGenerated}/.env`) {
    | path => Some(path)
    | exception _exn => None
    }
}

let initialize = () => config({path: ?Utils.getEnvFilePath()})->ignore
