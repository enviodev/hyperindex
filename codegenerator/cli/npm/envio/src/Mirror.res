type t = {
  initialize: (
    ~chainConfigs: array<Config.chain>=?,
    ~entities: array<Internal.entityConfig>=?,
    ~enums: array<Internal.enumConfig<Internal.enum>>=?,
  ) => promise<unit>,
}

let makeClickHouse = (~host): t => {
  initialize: (~chainConfigs=[], ~entities=[], ~enums=[]) => {
    Js.log({
      "host": host,
      "chainConfigs": chainConfigs,
      "entities": entities,
      "enums": enums,
    })
    Promise.resolve()
  },
}
