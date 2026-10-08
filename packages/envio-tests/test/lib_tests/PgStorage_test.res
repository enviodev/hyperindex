open Vitest

let config = TestConfig.make()
let ecosystem = config.ecosystem

// Runs the validation path in makeStorageFromEnv taken only when
// `storage.clickhouse: true` in config.yaml. The vars are cleared around the
// call rather than assumed absent: the scenario's own ClickHouse tests need them
// set, so an ambient value would leave nothing missing to report.
let withoutClickHouseEnv = fn => {
  let names = [
    "ENVIO_CLICKHOUSE_HOST",
    "ENVIO_CLICKHOUSE_USERNAME",
    "ENVIO_CLICKHOUSE_PASSWORD",
    "ENVIO_CLICKHOUSE_DATABASE",
  ]
  let env = NodeJs.Process.process.env
  let saved = names->Array.map(name => (name, env->Utils.Dict.dangerouslyGetNonOption(name)))
  names->Array.forEach(name => env->Dict.delete(name))
  let result = try Ok(fn()) catch {
  | exn => Error(exn)
  }
  saved->Array.forEach(((name, value)) =>
    switch value {
    | Some(value) => env->Dict.set(name, value)
    | None => ()
    }
  )
  switch result {
  | Ok(value) => value
  | Error(exn) => throw(exn)
  }
}

describe("PgStorage.makeStorageFromEnv ClickHouse env var validation", () => {
  Async.it(
    "Throws listing all missing ENVIO_CLICKHOUSE_* env vars when storage.clickhouse=true",
    async t => {
      let config = {
        ...config,
        storage: (
          {
            postgres: true,
            clickhouse: true,
            postgresColumnNameFormat: Original,
            clickhouseColumnNameFormat: Original,
          }: Config.storage
        ),
      }
      let message = withoutClickHouseEnv(
        () =>
          switch try {
            let _ = PgStorage.makeStorageFromEnv(~config)
            None
          } catch {
          | JsExn(e) => Some(e->JsExn.message->Option.getOr(""))
          | _ => None
          } {
          | Some(m) => m
          | None => ""
          },
      )
      t.expect(
        message,
        ~message="Should throw a helpful error naming every missing env var at once",
      ).toBe(
        "ClickHouse storage is enabled but required env vars are not set: ENVIO_CLICKHOUSE_HOST, ENVIO_CLICKHOUSE_USERNAME, ENVIO_CLICKHOUSE_PASSWORD, ENVIO_CLICKHOUSE_DATABASE. Please set them, disable clickhouse in the `storage` config, or run `envio dev` for a pre-configured local ClickHouse.",
      )
    },
  )

  Async.it("Does not throw when storage.clickhouse=false (default)", async t => {
    let config = {
      ...config,
      storage: (
        {
          postgres: true,
          clickhouse: false,
          postgresColumnNameFormat: Original,
          clickhouseColumnNameFormat: Original,
        }: Config.storage
      ),
    }
    // Just ensure construction succeeds without touching ClickHouse env vars.
    let _ = PgStorage.makeStorageFromEnv(~config)
    t.expect(true, ~message="Expected no throw when clickhouse is disabled").toBe(true)
  })

  // `envio dev` applies ENVIO_CLICKHOUSE_* vars via Bin.applyEnv, which runs
  // AFTER Env.res has been imported. If Env.ClickHouse cached reads at module
  // load, those late writes would be invisible and validation would still
  // throw. This test simulates that timing by writing the vars to process.env
  // right before calling makeStorageFromEnv.
  Async.it("Picks up ENVIO_CLICKHOUSE_* vars set after Env.res has been loaded", async t => {
    let getEnvVar: string => option<string> = %raw(`(k) => process.env[k]`)
    let setEnvVar: (string, string) => unit = %raw(`(k, v) => { process.env[k] = v; }`)
    let unsetEnvVar: string => unit = %raw(`(k) => { delete process.env[k]; }`)
    // The ClickHouse leg points the process at its own database through these
    // same vars, so deleting them unconditionally would strip the run's wiring
    // from every test after this one in the file.
    let restored = [
      ("ENVIO_CLICKHOUSE_HOST", "http://localhost:8123"),
      ("ENVIO_CLICKHOUSE_USERNAME", "default"),
      ("ENVIO_CLICKHOUSE_PASSWORD", "testing"),
      ("ENVIO_CLICKHOUSE_DATABASE", "envio_indexer"),
    ]->Array.map(
      ((key, value)) => {
        let before = getEnvVar(key)
        setEnvVar(key, value)
        (key, before)
      },
    )
    let config = {
      ...config,
      storage: (
        {
          postgres: true,
          clickhouse: true,
          postgresColumnNameFormat: Original,
          clickhouseColumnNameFormat: Original,
        }: Config.storage
      ),
    }
    let result = try {
      let _ = PgStorage.makeStorageFromEnv(~config)
      Ok()
    } catch {
    | JsExn(e) => Error(e->JsExn.message->Option.getOr(""))
    | _ => Error("non-JsExn")
    }
    restored->Array.forEach(
      ((key, before)) =>
        switch before {
        | Some(value) => setEnvVar(key, value)
        | None => unsetEnvVar(key)
        },
    )
    t.expect(
      result,
      ~message="Should read ClickHouse env vars lazily so envio dev's late injection works",
    ).toEqual(Ok())
  })
})

describe("ecosystem.toRawEvent", () => {
  Async.it(
    "Derives a raw event row from a batch item, taking block hash and timestamp from the payload block and stringifying bigint block fields",
    async t => {
      let srcAddress =
        "0x00000000000000000000000000000000000000ab"->(Utils.magic: string => Address.t)
      let blockNumber = 5
      let logIndex = 3

      let event = {
        "block": %raw(`{"number": 5, "timestamp": 9999, "hash": "0xblockhash", "gasUsed": 99n, "miner": "0xminer"}`),
        "transaction": %raw(`{"hash": "0xtxhash", "transactionIndex": 2}`),
        "params": (),
        "logIndex": logIndex,
        "srcAddress": srcAddress,
        "chainId": 137,
        "contractName": "ERC20",
        "eventName": "EventWithoutFields",
      }->(
        Utils.magic: {
          "block": JSON.t,
          "transaction": JSON.t,
          "params": unit,
          "logIndex": int,
          "srcAddress": Address.t,
          "chainId": int,
          "contractName": string,
          "eventName": string,
        } => Internal.eventPayload
      )

      let eventItem = Internal.Event({
        onEventRegistration: (EventRegistration.evmOnEventRegistration(
          ~contractName="ERC20",
        ) :> Internal.onEventRegistration),
        chainId: 137->ChainId.fromInt,
        blockNumber,
        logIndex,
        transactionIndex: 0,
        payload: event,
      })->Internal.castUnsafeEventItem

      t.expect(ecosystem.toRawEvent(eventItem)).toEqual({
        chain_id: 137->ChainId.fromInt,
        event_id: EventUtils.packEventIndex(~logIndex, ~blockNumber),
        event_name: "EventWithoutFields",
        contract_name: "ERC20",
        block_number: blockNumber,
        log_index: logIndex,
        src_address: srcAddress,
        block_hash: "0xblockhash",
        block_timestamp: 9999,
        block_fields: %raw(`{"gasUsed": "99", "miner": "0xminer"}`),
        transaction_fields: %raw(`{"hash": "0xtxhash", "transactionIndex": 2}`),
        params: %raw(`"null"`),
      })
    },
  )
})
