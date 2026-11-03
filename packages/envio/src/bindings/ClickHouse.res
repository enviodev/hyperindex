// Every connection setting has to be there: an unset one would otherwise reach
// the server as an empty value and fail there, for a reason naming neither.
let optionsFromEnvOrThrow = (): StorageClient.clickHouseOptions => {
  let missing = []
  let required = (value, name) =>
    switch value {
    | Some(value) => value
    | None =>
      missing->Array.push(name)
      ""
    }
  let url = Env.ClickHouse.host()->required("ENVIO_CLICKHOUSE_HOST")
  let username = Env.ClickHouse.username()->required("ENVIO_CLICKHOUSE_USERNAME")
  let password = Env.ClickHouse.password()->required("ENVIO_CLICKHOUSE_PASSWORD")
  let database = Env.ClickHouse.database()->required("ENVIO_CLICKHOUSE_DATABASE")
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
    replicated: Env.ClickHouse.replicated(),
    databaseEngine: ?Env.ClickHouse.databaseEngine(),
  }
}
