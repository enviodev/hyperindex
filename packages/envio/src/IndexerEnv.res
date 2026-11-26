// The environment as Rust read and validated it (`indexer_env.rs`). The
// runtime takes it as config and never reads the environment itself.

// Puts the working directory's .env into the process environment, where Rust
// reads it and where user handlers expect it in `process.env`.
%%raw(`import 'dotenv/config'`)

type serializationFormat = | @as("Json") Json | @as("CapnProto") CapnProto

type hyperSync = {
  clientTimeoutMillis: int,
  serializationFormat: serializationFormat,
  enableQueryCaching: bool,
  logFilter: string,
}

type rpcSync = {
  initialBlockInterval?: int,
  backoffMultiplicative?: float,
  accelerationAdditive?: int,
  intervalCeiling?: int,
}

type logger = {
  strategy: string,
  file: string,
  // Unset means the entry point's own default: info for a run, silent for a
  // test indexer.
  level?: Logger.level,
  fileLevel: Logger.level,
}

type db = {
  host: string,
  port: int,
  user: string,
  password: string,
  database: string,
  schema: string,
  sslMode: string,
  // The budget for the whole run, not for one process: a run that splits
  // across workers divides it among them.
  maxConnections: int,
}

type clickHouse = {
  host?: string,
  database?: string,
  username?: string,
  password?: string,
  replicated: bool,
  databaseEngine?: string,
}

type hasura = {
  enabled: bool,
  responseLimit?: int,
  graphqlEndpoint: string,
  url: string,
  role: string,
  secret: string,
  aggregateEntities: array<string>,
}

type throttle = {
  chainMetadataIntervalMillis: int,
  pruneStaleDataIntervalMillis: int,
}

type t = {
  // The whole-indexer fetch buffer pool, independent of chain count. A buffered
  // item takes about 360 bytes of process memory.
  indexingMaxBufferSize: int,
  maxPartitionSize: int,
  clientFilterAddressThreshold?: int,
  // Uncommitted entity/effect changes plus unwritten batch items the store
  // holds before processing waits for the write cycle to catch up.
  inMemoryObjectsTarget: int,
  serverPort: int,
  // Whether this process draws the progress display: `ENVIO_TUI` first, then
  // whether anything is watching.
  tui: bool,
  envioAppUrl: string,
  envioApiToken?: string,
  hyperSync: hyperSync,
  rpcSync: rpcSync,
  logger: logger,
  db: db,
  clickHouse: clickHouse,
  hasura: hasura,
  throttle: throttle,
  internalWorker?: string,
}

let prodEnvioAppUrl = "https://envio.dev"

let read = (): t => Core.getAddon().readIndexerEnv()->JSON.parseOrThrow->(Utils.magic: JSON.t => t)
