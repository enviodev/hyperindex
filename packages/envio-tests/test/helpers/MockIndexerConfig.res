type parsed = {
  config: Config.t,
  publicConfigJson: JSON.t,
}

// Parse the same YAML a user supplies, then cross the public JSON boundary used at runtime.
let parseYaml = (~schema=?, ~env=?, ~files=?, ~isRescript=false, yaml): parsed => {
  let publicConfigJson =
    Core.parseConfigYaml(~schema?, ~env?, ~files?, ~isRescript, yaml)->JSON.parseOrThrow
  {
    publicConfigJson,
    config: Config.fromPublic(publicConfigJson),
  }
}
