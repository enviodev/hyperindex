type t = {
  initialize: (
    ~chainConfigs: array<Config.chain>=?,
    ~entities: array<Internal.entityConfig>=?,
    ~enums: array<Internal.enumConfig<Internal.enum>>=?,
  ) => promise<unit>,
  setOrThrow: 'item. (
    ~items: array<'item>,
    ~table: Table.table,
    ~itemSchema: S.t<'item>,
  ) => promise<unit>,
}

let makeClickHouse = (~host, ~database, ~username, ~password): t => {
  let client = ClickHouse.createClient({
    url: host,
    username,
    password,
  })

  {
    initialize: (~chainConfigs as _=[], ~entities=[], ~enums=[]) => {
      ClickHouse.initialize(client, ~database, ~entities, ~enums)
    },
    setOrThrow: (~items, ~table, ~itemSchema) => {
      ClickHouse.setOrThrow(client, ~items, ~table, ~itemSchema, ~database)
    },
  }
}
