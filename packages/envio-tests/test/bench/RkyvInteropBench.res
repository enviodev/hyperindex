// An experiment, not a test: the real storage path that
// scripts/rkyvInteropBench.mjs measures an rkyv archive against. Entities are
// staged into the arena the way a batch write stages them, and read back the
// way a load reads them, against a running Postgres.

let config = InternalTestIndexer.fromUserApi(
  ~schema=`
type Account {
  id: ID!
  owner: String!
  balance: BigInt!
  transfers: Int!
  active: Boolean!
  ratio: Float
}
`,
  ~configYaml=`
name: rkyv-interop
chains:
  - id: 1
    start_block: 0
`,
).config

let entityConfig = config.userEntitiesByName->Dict.getUnsafe("Account")

let client = Storage.makeClient(
  ~logger=Logger.makeInMemory(),
  ~config,
  ~postgres=Storage.postgresOptions(~maxConnections=1),
)

let writers =
  (client->StorageClient.layouts).entities
  ->Array.getUnsafe(entityConfig.index)
  ->(layout => layout.StorageClient.fields)
  ->StagedRows.writersOf

// A batch write's staging of one entity's changes, up to the arena handed back.
let stage = (changes: array<Change.t<Internal.entity>>) =>
  client
  ->StorageClient.arena((~rows) =>
    client->StorageClient.beginChanges(~entity=entityConfig.index, ~rows)
  )
  ->Storage.stageChangesOrThrow(~writers, ~changes)

let discard = handle => client->StorageClient.discardStaged([handle])

// Rows Postgres returns in the arena, as a load's would be.
let query = (~count) =>
  client->StorageClient.queryForTestsRaw(
    `select 'account-' || g as id, '0x' || lpad(to_hex(g * 7), 40, '0') as owner, (g::numeric * 1000000000000000000) as balance, (g % 1000)::int as transfers, (g % 3 <> 0) as active, case when g % 2 = 0 then g / 7.0::float8 end as ratio from generate_series(0, ${(count - 1)->Int.toString}) g`,
    [],
  )

// A load's crossing: the arena lent, read into rows, and the rows parsed into
// entities.
let read = result =>
  client
  ->StorageClient.read(result)
  ->(Utils.magic: array<dict<unknown>> => array<unknown>)
  ->S.parseOrThrow(entityConfig.table->Table.pgRowsSchema)
