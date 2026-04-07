// Helpers used by the TypeScript test files (entity-column-types,
// raw-events-table-migration, etc.) via the generated TestHelpers.gen.ts.
// Written in ReScript so we can call envio's Migrations module directly
// without wrestling with Node's ESM type-stripping rules for node_modules.

@module("fs") external readFileSync: (string, string) => string = "readFileSync"

let setEnvioConfig: string => unit = %raw(`json => { process.env.ENVIO_CONFIG = json }`)

// Migrations.runUpMigrations reads the config via Config.fromEnv() which
// looks at process.env.ENVIO_CONFIG. Load it once here from the generated
// internal.config.json so per-file beforeAll/afterAll hooks can call
// runUpMigrations in-process without spawning a subprocess.
let _: unit = {
  let helpersDir = NodeJs.Path.getDirname(NodeJs.ImportMeta.importMeta)
  let configPath = NodeJs.Path.join(helpersDir, "../../generated/internal.config.json")
  let json = readFileSync(configPath->NodeJs.Path.toString, "utf-8")
  setEnvioConfig(json)
}

@genType
let createSql = () => PgStorage.makeClient()

let runMigrationsNoExit = async () => {
  // shouldExit=false, reset=true — matches the pre-refactor behaviour
  // of fully re-creating the DB schema between test files.
  let _ = await Migrations.runUpMigrations(~shouldExit=false, ~reset=true)
}

// Preserve the original console.log on the first load, then let
// disable/enable toggle between the no-op and the saved function.
let _: unit = %raw(`globalThis.__origConsoleLog ||= console.log`)

let disableConsoleLog = () => {
  let _: unit = %raw(`(console.log = () => undefined)`)
}

let enableConsoleLog = () => {
  let _: unit = %raw(`(console.log = globalThis.__origConsoleLog)`)
}

let runFunctionNoLogs = async (func: unit => promise<unit>) => {
  disableConsoleLog()
  await func()
  enableConsoleLog()
}

@genType
let runMigrationsNoLogs = () => runFunctionNoLogs(runMigrationsNoExit)
