// Every connection setting has to be there: an unset one would otherwise reach
// the server as an empty value and fail there, for a reason naming neither.
let optionsOrThrow = (env: IndexerEnv.clickHouse): StorageClient.clickHouseOptions => {
  let missing = []
  let required = (value, name) =>
    switch value {
    | Some(value) => value
    | None =>
      missing->Array.push(name)
      ""
    }
  let url = env.host->required("ENVIO_CLICKHOUSE_HOST")
  let username = env.username->required("ENVIO_CLICKHOUSE_USERNAME")
  let password = env.password->required("ENVIO_CLICKHOUSE_PASSWORD")
  let database = env.database->required("ENVIO_CLICKHOUSE_DATABASE")
  if missing->Utils.Array.notEmpty {
    JsError.throwWithMessage(
      `ClickHouse storage is enabled but required env vars are not set: ${missing->Array.joinUnsafe(
          ", ",
        )}. Please set them, disable clickhouse in the \`storage\` config, or run \`envio dev\` for a pre-configured local ClickHouse.`,
    )
  }
  {
    url,
    username,
    password,
    database,
    replicated: env.replicated,
    databaseEngine: ?env.databaseEngine,
  }
}
