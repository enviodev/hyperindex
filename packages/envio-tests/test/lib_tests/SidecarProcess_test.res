open Vitest

describe("SidecarProcess.closeCapMs", () => {
  // The pod's termination grace is 30 s, so whatever ENVIO_SIDECAR_GRACE_MS
  // says, `envio sidecar` exits by 28 s.
  it("waits the runtime's grace plus 2 s, defaults to 22 s and caps at 28 s", t => {
    t.expect(
      [
        None,
        Some(""),
        Some("abc"),
        Some("-1"),
        Some("0"),
        Some("500"),
        Some("20000"),
        Some("26001"),
        Some("2147483647"),
      ]->Array.map(graceMs => SidecarProcess.closeCapMs(~graceMs)),
    ).toEqual([22_000, 22_000, 22_000, 22_000, 2_000, 2_500, 22_000, 28_000, 28_000])
  })
})

describe("SidecarProcess.devEnv", () => {
  let pgKeys = [
    "UNRELATED",
    "ENVIO_SIDECAR_PG_HOST",
    "ENVIO_SIDECAR_PG_PORT",
    "ENVIO_SIDECAR_PG_DATABASE",
    "ENVIO_SIDECAR_PG_USER",
    "ENVIO_SIDECAR_PG_PASSWORD",
    "ENVIO_SIDECAR_PG_SCHEMA",
    "ENVIO_SIDECAR_PG_SSL_MODE",
    "ENVIO_SIDECAR_PG_POOLER_BACKED",
  ]

  it("points the sidecar's sql handle at the indexer's database as envio_sidecar", t => {
    let env = SidecarProcess.devEnv(~env=Dict.fromArray([("UNRELATED", "kept")]), ())
    t.expect(pgKeys->Array.map(key => env->Dict.get(key))).toEqual([
      Some("kept"),
      Some(Env.Db.host),
      Some(Env.Db.port->Int.toString),
      Some(Env.Db.database),
      Some("envio_sidecar"),
      Some("testing"),
      Some(Env.Db.publicSchema),
      Some(Env.Db.ssl->Sql.sslModeToString),
      Some("false"),
    ])
  })

  it("keeps a value the developer set, treats an empty one as unset, copies the env", t => {
    let developerEnv = Dict.fromArray([
      ("ENVIO_SIDECAR_PG_HOST", "db.internal"),
      ("ENVIO_SIDECAR_PG_USER", "my_reader"),
      ("ENVIO_SIDECAR_PG_PASSWORD", "secret"),
      ("ENVIO_SIDECAR_PG_SCHEMA", ""),
    ])
    let env = SidecarProcess.devEnv(~env=developerEnv, ())
    t.expect((
      pgKeys->Array.map(key => env->Dict.get(key)),
      developerEnv->Dict.get("ENVIO_SIDECAR_PG_PORT"),
    )).toEqual((
      [
        None,
        Some("db.internal"),
        Some(Env.Db.port->Int.toString),
        Some(Env.Db.database),
        Some("my_reader"),
        Some("secret"),
        Some(Env.Db.publicSchema),
        Some(Env.Db.ssl->Sql.sslModeToString),
        Some("false"),
      ],
      None,
    ))
  })
})
