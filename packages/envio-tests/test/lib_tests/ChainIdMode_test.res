open Vitest

let schema = `
type Transfer {
  id: ID!
  amount: BigInt!
}
`

let parse = (~name, ~chains) =>
  InternalTestIndexer.fromUserApi(
    ~schema,
    ~configYaml=`
name: ${name}
chains:
${chains}
`,
  ).config

let evmChain = (~id, ~rpc="https://rpc.example.test") => `  - id: ${id}
    rpc: ${rpc}
    start_block: 0`

let maxInt32Config = parse(~name="max-int32", ~chains=evmChain(~id="2147483647"))
let overInt32Config = parse(~name="over-int32", ~chains=evmChain(~id="2147483648"))
let tronConfig = parse(
  ~name="tron-testnets",
  ~chains=evmChain(~id="2494104990") ++ "\n" ++ evmChain(~id="3448148188"),
)
let multichainConfig = parse(
  ~name="multichain",
  ~chains=evmChain(~id="1") ++ "\n" ++ evmChain(~id="4503599627370496"),
)
let maxSafeConfig = parse(~name="max-safe", ~chains=evmChain(~id="9007199254740991"))

let chainsDdl = (config: Config.t) =>
  PgStorage.makeCreateTableQuery(
    InternalTable.Chains.table,
    ~pgSchema="test_schema",
    ~isNumericArrayAsText=false,
    ~chainIdMode=config.chainIdMode,
  )

let addressesDdl = (config: Config.t) =>
  PgStorage.makeCreateTableQuery(
    InternalTable.EnvioAddresses.table,
    ~pgSchema="test_schema",
    ~isNumericArrayAsText=false,
    ~chainIdMode=config.chainIdMode,
  )

let rawEventsDdl = (config: Config.t) =>
  PgStorage.makeCreateTableQuery(
    InternalTable.RawEvents.table,
    ~pgSchema="test_schema",
    ~isNumericArrayAsText=false,
    ~chainIdMode=config.chainIdMode,
  )

describe("ChainIdMode resolution", () => {
  it("keeps Int32 at the int32 boundary and widens one above it", t => {
    t.expect((
      maxInt32Config.chainIdMode,
      overInt32Config.chainIdMode,
      tronConfig.chainIdMode,
      multichainConfig.chainIdMode,
      maxSafeConfig.chainIdMode,
    )).toEqual((ChainId.Int32, ChainId.Int64, ChainId.Int64, ChainId.Int64, ChainId.Int64))
  })

  it("parses wide chain ids losslessly through the public config", t => {
    t.expect(
      [tronConfig, multichainConfig, maxSafeConfig]->Array.map(config =>
        config.chainMap->ChainMap.keys->Array.map(ChainId.toString)
      ),
    ).toEqual([
      ["2494104990", "3448148188"],
      ["1", "4503599627370496"],
      ["9007199254740991"],
    ])
  })

  it("rejects a chain id above Number.MAX_SAFE_INTEGER", t => {
    t->toThrowErrorEqual(
      () => parse(~name="too-big", ~chains=evmChain(~id="9007199254740992"))->ignore,
      "Chain id 9007199254740992 is above the maximum supported chain id 9007199254740991 (Number.MAX_SAFE_INTEGER).",
    )
  })

  it("counts skipped chains, which codegen still emits a chainId case for", t => {
    let skippedWide = `  - id: 1
    rpc: https://rpc.example.test
    start_block: 0
  - id: 2494104990
    skip: true
    rpc: https://rpc.example.test
    start_block: 0`
    t.expect(parse(~name="skipped-wide", ~chains=skippedWide).chainIdMode).toEqual(ChainId.Int64)
  })

  it("validates skipped chain ids too", t => {
    let skippedTooBig = `  - id: 1
    rpc: https://rpc.example.test
    start_block: 0
  - id: 9007199254740992
    skip: true
    rpc: https://rpc.example.test
    start_block: 0`
    t->toThrowErrorEqual(
      () => parse(~name="skipped-too-big", ~chains=skippedTooBig)->ignore,
      "Chain id 9007199254740992 is above the maximum supported chain id 9007199254740991 (Number.MAX_SAFE_INTEGER).",
    )
  })

  it("resolves the mode from the widest chain, not the first one", t => {
    t.expect(
      parse(~name="wide-second", ~chains=evmChain(~id="1") ++ "\n" ++ evmChain(~id="2147483648")).chainIdMode,
    ).toEqual(ChainId.Int64)
  })
})

describe("ChainIdMode public config JSON", () => {
  let rawConfigJson = (~id) =>
    Core.fromUserApi(
      ~schema,
      `
name: raw-json
chains:
${evmChain(~id)}
`,
    ).config->JSON.parseOrThrow

  let chainIdModeKey = json =>
    switch json {
    | JSON.Object(dict) => dict->Dict.get("chainIdMode")
    | _ => None
    }

  it("omits the key on Int32 so existing configs keep the same fingerprint", t => {
    t.expect((
      rawConfigJson(~id="2147483647")->chainIdModeKey,
      rawConfigJson(~id="2147483648")->chainIdModeKey,
    )).toEqual((None, Some(JSON.String("int64"))))
  })
})

describe("ChainIdMode Postgres schema", () => {
  it("keeps INTEGER chain-id columns for small-id projects", t => {
    t.expect((
      maxInt32Config->chainsDdl,
      maxInt32Config->addressesDdl,
      maxInt32Config->rawEventsDdl,
    )).toEqual((
      `CREATE TABLE IF NOT EXISTS "test_schema"."envio_chains"("id" INTEGER NOT NULL, "ecosystem" TEXT NOT NULL, "start_block" INTEGER NOT NULL, "end_block" INTEGER, "max_reorg_depth" INTEGER NOT NULL, "buffer_block" INTEGER NOT NULL, "source_block" INTEGER NOT NULL, "first_event_block" INTEGER, "ready_at" TIMESTAMP WITH TIME ZONE NULL, "events_processed" BIGINT NOT NULL, "_is_hyper_sync" BOOLEAN NOT NULL, "progress_block" INTEGER NOT NULL, PRIMARY KEY("id"));`,
      `CREATE TABLE IF NOT EXISTS "test_schema"."envio_addresses"("chain_id" INTEGER NOT NULL, "address" BYTEA NOT NULL, "contract_id" SMALLINT NOT NULL, "registration_block" INTEGER NOT NULL, PRIMARY KEY("chain_id", "address", "contract_id"));`,
      `CREATE TABLE IF NOT EXISTS "test_schema"."raw_events"("chain_id" INTEGER NOT NULL, "event_id" BIGINT NOT NULL, "event_name" TEXT NOT NULL, "contract_name" TEXT NOT NULL, "block_number" INTEGER NOT NULL, "log_index" INTEGER NOT NULL, "src_address" TEXT NOT NULL, "block_hash" TEXT NOT NULL, "block_timestamp" INTEGER NOT NULL, "block_fields" JSONB NOT NULL, "transaction_fields" JSONB NOT NULL, "params" JSONB NOT NULL, "serial" BIGSERIAL, PRIMARY KEY("serial"));`,
    ))
  })

  it("widens every chain-id column to BIGINT in Int64 mode", t => {
    t.expect((
      tronConfig->chainsDdl,
      tronConfig->addressesDdl,
      tronConfig->rawEventsDdl,
    )).toEqual((
      maxInt32Config->chainsDdl->String.replace(`"id" INTEGER`, `"id" BIGINT`),
      maxInt32Config->addressesDdl->String.replace(`"chain_id" INTEGER`, `"chain_id" BIGINT`),
      maxInt32Config->rawEventsDdl->String.replace(`"chain_id" INTEGER`, `"chain_id" BIGINT`),
    ))
  })

  it("selects the array cast for chain-id parameters from the mode", t => {
    t.expect((
      InternalTable.Checkpoints.makeInsertCheckpointQuery(
        ~pgSchema="test_schema",
        ~chainIdMode=maxInt32Config.chainIdMode,
      ),
      InternalTable.Checkpoints.makeInsertCheckpointQuery(
        ~pgSchema="test_schema",
        ~chainIdMode=tronConfig.chainIdMode,
      ),
      InternalTable.EnvioAddresses.makeInsertQuery(
        ~pgSchema="test_schema",
        ~chainIdMode=tronConfig.chainIdMode,
      )->String.includes("$1::BIGINT[]"),
    )).toEqual((
      `INSERT INTO "test_schema"."envio_checkpoints" ("id", "chain_id", "block_number", "block_hash", "events_processed")
SELECT * FROM unnest($1::BIGINT[],$2::INTEGER[],$3::INTEGER[],$4::TEXT[],$5::INTEGER[]);`,
      `INSERT INTO "test_schema"."envio_checkpoints" ("id", "chain_id", "block_number", "block_hash", "events_processed")
SELECT * FROM unnest($1::BIGINT[],$2::BIGINT[],$3::INTEGER[],$4::TEXT[],$5::INTEGER[]);`,
      true,
    ))
  })
})

// The mode decides whether a chain id is an Int32 or a UInt64 column, which
// Rust derives. The wire kind it resolves is how that reaches this side, and
// picking the wrong one would hand the column the wrong typed array.
describe("ChainIdMode ClickHouse schema", () => {
  it("maps the checkpoints chain_id column from the mode", t => {
    let chainIdKind = (config: Config.t) => {
      let sink = ClickHouse.makeSink(
        ~host="http://127.0.0.1:1",
        ~username="default",
        ~password="",
        ~database="unused",
        ~chainIdMode=config.chainIdMode,
      )
      let specs = ClickHouse.checkpointColumnSpecs
      let {kinds} = sink->ClickHouseSink.registerCheckpointsTable(specs)
      let column = specs->Array.findIndexOpt(({name}) => name === "chain_id")->Option.getOrThrow
      kinds->Array.getUnsafe(column)->ClickHouseSink.kindOfOrdinal
    }
    t.expect((maxInt32Config->chainIdKind, tronConfig->chainIdKind)).toEqual((
      ClickHouseSink.F64,
      ClickHouseSink.U64,
    ))
  })
})

describe("ChainId runtime representation", () => {
  it("round-trips BIGINT results returned as strings", t => {
    t.expect((
      "3448148188"->ChainId.normalizeOrThrow->ChainId.toString,
      3448148188.->ChainId.normalizeOrThrow->ChainId.toString,
      ChainId.compare("1"->ChainId.normalizeOrThrow, "2147483648"->ChainId.normalizeOrThrow),
      "42"->ChainId.normalizeOrThrow === 42->ChainId.fromInt,
    )).toEqual(("3448148188", "3448148188", -1, true))
  })

  it("rejects values that can't be a chain id", t => {
    t.expect(
      ["-1", "1.5", "9007199254740992", "abc"]->Array.map(value =>
        try {
          value->ChainId.normalizeOrThrow->ChainId.toString
        } catch {
        | _ => "rejected"
        }
      ),
    ).toEqual(["rejected", "rejected", "rejected", "rejected"])
  })
})

// The ReScript `chainId` type is the one generated surface that changes with
// the mode, so assert on the generated code rather than the config JSON.
let generatedRescript = (~id) =>
  Core.fromUserApi(
    ~schema,
    ~withIndexerTypes=true,
    `
name: generated-rescript
chains:
${evmChain(~id)}
`,
  ).indexerCode->Null.getOrThrow

describe("ChainIdMode generated ReScript surface", () => {
  it("keeps the polyvariant union and its exhaustive match for int32 ids", t => {
    let code = generatedRescript(~id="2147483647")
    t.expect((
      code->String.includes("type chainId = [#2147483647]"),
      code->String.includes("switch chainId {\n  | #2147483647 => indexer.chains."),
      code->String.includes("type chainId = ChainId.t"),
    )).toEqual((true, true, false))
  })

  it("uses ChainId.t when only a skipped chain is wide", t => {
    // Skipped chains still get a `chainId` case, so `#2494104990` would be an
    // out-of-range int polyvariant if the mode ignored them.
    let code =
      Core.fromUserApi(
        ~schema,
        ~withIndexerTypes=true,
        `
name: skipped-wide-rescript
chains:
  - id: 1
    rpc: https://rpc.example.test
    start_block: 0
  - id: 2494104990
    skip: true
    rpc: https://rpc.example.test
    start_block: 0
`,
      ).indexerCode->Null.getOrThrow
    t.expect((
      code->String.includes("type chainId = ChainId.t"),
      code->String.includes("#2494104990"),
    )).toEqual((true, false))
  })

  it("falls back to ChainId.t when an id exceeds int32", t => {
    // ReScript integer polyvariants are int32-bound, so a wide config can't use
    // them — getChainById becomes a keyed lookup instead of an exhaustive match.
    let code = generatedRescript(~id="2494104990")
    t.expect((
      code->String.includes("type chainId = ChainId.t"),
      code->String.includes("->Dict.get(chainId->ChainId.toString)"),
      code->String.includes("type chainId = [#"),
    )).toEqual((true, true, false))
  })
})

describe("ChainIdMode generated TypeScript surface", () => {
  it("keeps chain.id a number and the id union a numeric literal union", _ =>
    InternalTestIndexer.fromUserApi(
      ~schema,
      ~configYaml=`
name: wide-ts-api
${"chains:\n" ++ evmChain(~id="2494104990") ++ "\n" ++ evmChain(~id="3448148188")}
`,
      ~handlers=`
import type { EvmChainId } from "envio";
import { expectType, type TypeEqual } from "ts-expect";
import { indexer } from "envio";

expectType<TypeEqual<EvmChainId, 2494104990 | 3448148188>>(true);
expectType<number>(indexer.chains[2494104990].id);
`,
    )->ignore
  )
})

describe("ChainIdMode generated handler context", () => {
  it("types context.chain.id as the generated chainId, not int", _ =>
    InternalTestIndexer.fromUserApi(
      ~schema,
      ~configYaml=`
name: wide-handler-context
${"chains:\n" ++ evmChain(~id="2494104990")}
`,
      ~handlers=`
import { expectType, type TypeEqual } from "ts-expect";
import type { EvmOnEventContext } from "envio";

expectType<TypeEqual<EvmOnEventContext["chain"]["id"], 2494104990>>(true);
`,
    )->ignore
  )
})

describe("ChainIdMode compat check", () => {
  it("reports a stored/current mode mismatch on its own", t => {
    // Int32 omits the key entirely, so widening shows up as an added key.
    let int32 = `{"version": "1.0.0", "name": "demo"}`->JSON.parseOrThrow
    let int64 = `{"version": "1.0.0", "chainIdMode": "int64", "name": "demo"}`->JSON.parseOrThrow
    t.expect((
      Config.diffPaths(~stored=int32, ~current=int64),
      Config.diffPaths(~stored=int64, ~current=int32),
      Config.diffPaths(~stored=int32, ~current=int32),
    )).toEqual((["chainIdMode"], ["chainIdMode"], []))
  })

  it("fails the resume with the standard incompatible-config message", t => {
    t->toThrowErrorEqual(
      () =>
        Config.throwIfIncompatible(
          ["chainIdMode"],
          ~resetCommand="envio local db-migrate setup",
          ~runCommand=None,
          ~hasClickhouse=false,
        ),
      `The following config changes are incompatible with the existing indexer data:

    - chainIdMode

Pick one:
  1. Revert the changes above      # resume indexing where it left off
  2. envio local db-migrate setup  # delete all indexed data and start over`,
    )
  })
})
