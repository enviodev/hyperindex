let getEnvVar = (~typ, ~fallback=?, ~envSafe as env, name) => {
  let struct = switch fallback {
  | Some(fallbackContent) => typ->S.option->S.default(() => fallbackContent)
  | None => typ
  }
  env->EnvSafe.get(~name, ~struct, ())
}

let getStringEnvVar = getEnvVar(~typ=S.string())
let getOptStringEnvVar = getEnvVar(~typ=S.string()->S.option)
let getIntEnvVar = getEnvVar(~typ=S.int())
let getOptIntEnvVar = getEnvVar(~typ=S.int()->S.option)
let getFloatEnvVar = getEnvVar(~typ=S.float())
let getBoolEnvVar = getEnvVar(~typ=S.bool())
