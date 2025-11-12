type t = {
  initialize: (
    ~chainConfigs: array<Config.chain>=?,
    ~entities: array<Internal.entityConfig>=?,
    ~enums: array<Internal.enumConfig<Internal.enum>>=?,
  ) => promise<unit>,
}

let makeClickHouse = (~host, ~database, ~username, ~password): t => {
  initialize: (~chainConfigs as _=[], ~entities=[], ~enums=[]) => {
    ClickHouse.initialize(~host, ~database, ~username, ~password, ~entities, ~enums)
  },
}
