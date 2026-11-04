open Vitest

// An `Address` field is a string to the handler whatever the storage keeps.
// Under `address_format: lowercase` Postgres keeps the raw 20 bytes in a bytea
// (an id, a foreign key, a list and an indexed column alike); with checksummed
// addresses the column stays text, so the case the handler wrote is the case
// it reads back.
let schema = `
type Token {
  id: Address!
  owner: Address! @index
  optOwner: Address
  owners: [Address!]!
  holders: [Holder!]! @derivedFrom(field: "token")
}
type Holder {
  id: ID!
  token: Token!
}
`

let configYaml = (~addressFormat, ~rollback=false) =>
  `
name: address-write-read
address_format: ${addressFormat}${rollback ? "\nrollback_on_reorg: true" : ""}
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0${rollback ? "\n    max_reorg_depth: 200" : ""}
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer()
`

type token = {
  id: string,
  owner: string,
  optOwner: option<string>,
  owners: array<string>,
}
type holder = {id: string, @as("token_id") tokenId: string}
type tokenFilter = {owner?: Envio.whereOperator<string>}
type holderFilter = {token_id?: Envio.whereOperator<string>}
type tokenOps = {
  set: token => unit,
  get: string => promise<option<token>>,
  getWhere: tokenFilter => promise<array<token>>,
  deleteUnsafe: string => unit,
}
type holderOps = {
  set: holder => unit,
  getWhere: holderFilter => promise<array<holder>>,
}
type handlerContext = {
  @as("Token") token: tokenOps,
  @as("Holder") holder: holderOps,
}

type loaded = {
  byId: option<token>,
  deleted: option<token>,
  byOwner: array<token>,
  byOwnerIn: array<token>,
  holders: array<holder>,
}

type column = {name: string, @as("type") type_: string}

let tokenItem = (~block, handler): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args =>
    await handler(args.context->(Utils.magic: Internal.handlerContext => handlerContext)),
}

// A store's share of an expectation: None when the run doesn't use it.
let onPostgres = value =>
  switch IndexerRunner.selectedBackend {
  | #postgres | #both => Some(value)
  | #clickhouse => None
  }
let onClickHouse = value =>
  switch IndexerRunner.selectedBackend {
  | #clickhouse | #both => Some(value)
  | #postgres => None
  }

let pgQuery = async (~indexer: IndexerRunner.t, query, ~params=[]) =>
  switch IndexerRunner.selectedBackend {
  | #postgres | #both =>
    let rows = ref([])
    await indexer.usePostgresSql(async sql =>
      rows := (await sql->Sql.queryForTests(query, ~params))
    )
    Some(rows.contents)
  | #clickhouse => None
  }

// Takes the query to build rather than its text: only a run that keeps
// ClickHouse has a database to name in it.
let chQuery = async (query: string => string) =>
  switch IndexerRunner.selectedBackend {
  | #clickhouse | #both =>
    let rows = await TestClickHouse.query(
      `${query(TestClickHouse.currentDatabase())} FORMAT JSONEachRow`,
    )
    Some(
      rows
      ->String.trim
      ->String.split("\n")
      ->Array.filter(row => row !== "")
      ->Array.map(row => row->JSON.parseOrThrow->(Utils.magic: JSON.t => 'row)),
    )
  | #postgres => None
  }

let pgColumns = (~indexer: IndexerRunner.t, ~tableName): promise<option<array<column>>> =>
  pgQuery(
    ~indexer,
    `SELECT a.attname::text AS name, pg_catalog.format_type(a.atttypid, a.atttypmod) AS type
FROM pg_attribute a
JOIN pg_class c ON a.attrelid = c.oid
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = $1 AND c.relname = $2 AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY a.attnum`,
    ~params=[
      indexer.pgSchema->(Utils.magic: string => unknown),
      tableName->(Utils.magic: string => unknown),
    ],
  )

let chColumns = (~tableName): promise<option<array<column>>> =>
  chQuery(database =>
    `SELECT name, type FROM system.columns WHERE database = '${database}' AND table = '${tableName}' AND NOT startsWith(name, 'envio_') ORDER BY position`
  )

let pgStoredTokens = (~indexer: IndexerRunner.t) =>
  pgQuery(
    ~indexer,
    `SELECT id::text AS id, owner::text AS owner, "optOwner"::text AS "optOwner", owners::text AS owners FROM "${indexer.pgSchema}"."Token" ORDER BY id`,
  )

let chStoredTokens = () =>
  chQuery(database =>
    `SELECT hex(id) AS id, hex(owner) AS owner, hex(optOwner) AS optOwner, arrayMap(x -> hex(x), owners) AS owners FROM \`${database}\`.\`Token\` ORDER BY id`
  )

// Sets two tokens and a holder of the first, deletes the second by id, then
// in a later batch reads the survivor back from storage by id, by an indexed
// Address column, and through the foreign key.
let run = async (~indexer: IndexerRunner.t, ~source: MockSource.t, ~kept, ~dropped) => {
  source.resolveGetHeightOrThrow(10)
  await source.expectItemsQueries([
    {
      fromBlock: 0,
      toBlock: Unbounded,
      reply: Respond({
        items: [
          tokenItem(~block=5, async context => {
            context.token.set(kept)
            context.token.set(dropped)
            context.holder.set({id: "h1", tokenId: kept.id})
            context.token.deleteUnsafe(dropped.id)
          }),
        ],
        latestFetchedBlockNumber: 5,
      }),
    },
  ])
  await indexer.getBatchWritePromise()

  let loaded = ref(None)
  await source.expectItemsQueries([
    {
      fromBlock: 6,
      toBlock: Unbounded,
      reply: Respond({
        items: [
          tokenItem(~block=6, async context => {
            loaded :=
              Some({
                byId: await context.token.get(kept.id),
                deleted: await context.token.get(dropped.id),
                byOwner: await context.token.getWhere({owner: {_eq: kept.owner}}),
                byOwnerIn: await context.token.getWhere({
                  owner: {_in: [dropped.owner, kept.owner]},
                }),
                holders: await context.holder.getWhere({token_id: {_eq: kept.id}}),
              })
          }),
        ],
        latestFetchedBlockNumber: 10,
      }),
    },
  ])
  await indexer.getBatchWritePromise()

  let tokens: array<token> = await indexer.query("Token")
  let holders: array<holder> = await indexer.query("Holder")
  (loaded.contents, tokens, holders)
}

describe("Address entity fields", () => {
  Scenario.make(
    ~schema,
    ~configYaml=configYaml(~addressFormat="lowercase"),
  )->Scenario.it(
    "keeps a lowercase address as its 20 bytes and reads it back as a string",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let kept = {
        id: "0x2b2f78c5bf6d9c12ee1225d5f374aa91204580c3",
        owner: "0x00000000000000000000000000000000000000aa",
        optOwner: Some("0xffffffffffffffffffffffffffffffffffffffff"),
        owners: [
          "0x0000000000000000000000000000000000000001",
          "0x00000000000000000000000000000000000000ff",
        ],
      }
      let dropped = {
        id: "0x1e645469f354bb4f5c8a05b3b30a929361cf77ec",
        owner: "0x00000000000000000000000000000000000000bb",
        optOwner: None,
        owners: [],
      }
      let result = await run(~indexer, ~source=source(1), ~kept, ~dropped)
      let stored = (
        await pgColumns(~indexer, ~tableName="Token"),
        await pgColumns(~indexer, ~tableName="Holder"),
        await pgStoredTokens(~indexer),
        await chColumns(~tableName="Token"),
        await chColumns(~tableName="Holder"),
        await chStoredTokens(),
      )
      t.expect((result, stored)).toEqual((
        (
          Some({
            byId: Some(kept),
            deleted: None,
            byOwner: [kept],
            byOwnerIn: [kept],
            holders: [{id: "h1", tokenId: kept.id}],
          }),
          [kept],
          [{id: "h1", tokenId: kept.id}],
        ),
        (
          onPostgres([
            {name: "id", type_: "bytea"},
            {name: "owner", type_: "bytea"},
            {name: "optOwner", type_: "bytea"},
            {name: "owners", type_: "bytea[]"},
          ]),
          onPostgres([{name: "id", type_: "text"}, {name: "token_id", type_: "bytea"}]),
          onPostgres([
            %raw(`{
              id: "\\x2b2f78c5bf6d9c12ee1225d5f374aa91204580c3",
              owner: "\\x00000000000000000000000000000000000000aa",
              optOwner: "\\xffffffffffffffffffffffffffffffffffffffff",
              owners: '{"\\\\x0000000000000000000000000000000000000001","\\\\x00000000000000000000000000000000000000ff"}',
            }`),
          ]),
          onClickHouse([
            {name: "id", type_: "FixedString(20)"},
            {name: "owner", type_: "FixedString(20)"},
            {name: "optOwner", type_: "Nullable(FixedString(20))"},
            {name: "owners", type_: "Array(FixedString(20))"},
          ]),
          onClickHouse([
            {name: "id", type_: "String"},
            {name: "token_id", type_: "FixedString(20)"},
          ]),
          onClickHouse([
            %raw(`{
              id: "2B2F78C5BF6D9C12EE1225D5F374AA91204580C3",
              owner: "00000000000000000000000000000000000000AA",
              optOwner: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
              owners: ["0000000000000000000000000000000000000001", "00000000000000000000000000000000000000FF"],
            }`),
          ]),
        ),
      ))
    },
  )

  Scenario.make(
    ~schema,
    ~configYaml=configYaml(~addressFormat="checksum"),
  )->Scenario.it("keeps a checksummed address as text, case and all", ~sources=[{chain: 1}], async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let kept = {
      id: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3",
      owner: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
      optOwner: None,
      owners: ["0x1E645469f354BB4F5c8a05B3b30A929361cf77eC"],
    }
    let dropped = {
      id: "0xA2F6E6029638CCB484A2CCB6414499AD3E825CAC",
      owner: "0x0000000000000000000000000000000000000001",
      optOwner: Some("0x0000000000000000000000000000000000000002"),
      owners: [],
    }
    let result = await run(~indexer, ~source=source(1), ~kept, ~dropped)
    let stored = (
      await pgColumns(~indexer, ~tableName="Token"),
      await pgColumns(~indexer, ~tableName="Holder"),
      await chColumns(~tableName="Token"),
      await chColumns(~tableName="Holder"),
    )
    t.expect((result, stored)).toEqual((
      (
        Some({
          byId: Some(kept),
          deleted: None,
          byOwner: [kept],
          byOwnerIn: [kept],
          holders: [{id: "h1", tokenId: kept.id}],
        }),
        [kept],
        [{id: "h1", tokenId: kept.id}],
      ),
      (
        onPostgres([
          {name: "id", type_: "text"},
          {name: "owner", type_: "text"},
          {name: "optOwner", type_: "text"},
          {name: "owners", type_: "text[]"},
        ]),
        onPostgres([{name: "id", type_: "text"}, {name: "token_id", type_: "text"}]),
        onClickHouse([
          {name: "id", type_: "String"},
          {name: "owner", type_: "String"},
          {name: "optOwner", type_: "Nullable(String)"},
          {name: "owners", type_: "Array(String)"},
        ]),
        onClickHouse([{name: "id", type_: "String"}, {name: "token_id", type_: "String"}]),
      ),
    ))
  })

  // A bytea keeps no case, so a value it couldn't give back as written is
  // refused rather than silently lowercased: two spellings of one address
  // would otherwise be two entities in memory and one row in storage.
  Scenario.make(
    ~schema,
    ~configYaml=configYaml(~addressFormat="lowercase"),
  )->Scenario.it(
    "refuses an address that isn't 20 lowercase bytes under address_format: lowercase",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(10)
      let refused = ref([])
      let lookedUp = ref([])
      await source.expectItemsQueries([
        {
          fromBlock: 0,
          toBlock: Unbounded,
          reply: Respond({
            items: [
              tokenItem(
                ~block=5,
                async context => {
                  let attempt = value =>
                    try {
                      context.token.set({id: value, owner: value, optOwner: None, owners: []})
                      "accepted"
                    } catch {
                    | JsExn(exn) => exn->JsExn.message->Option.getOr("")
                    }
                  let attemptAsync = async lookup =>
                    try {
                      let _ = await lookup()
                      "accepted"
                    } catch {
                    | JsExn(exn) => exn->JsExn.message->Option.getOr("")
                    }
                  refused :=
                    [
                      "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3",
                      "0x2b2f78c5bf6d9c12ee1225d5f374aa91204580",
                      "2b2f78c5bf6d9c12ee1225d5f374aa91204580c3",
                      "0x2b2f78c5bf6d9c12ee1225d5f374aa91204580zz",
                    ]->Array.map(attempt)
                  // Storage would match these spellings case-insensitively where
                  // the entities in memory don't.
                  lookedUp := [
                      await attemptAsync(
                        () => context.token.get("0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"),
                      ),
                      await attemptAsync(
                        () =>
                          context.token.getWhere({
                            owner: {_eq: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"},
                          }),
                      ),
                      await attemptAsync(
                        () =>
                          context.token.getWhere({
                            owner: {_in: ["0x2b2f78c5bf6d9c12ee1225d5f374aa91204580c3", "0xAA"]},
                          }),
                      ),
                    ]
                },
              ),
            ],
            latestFetchedBlockNumber: 5,
          }),
        },
      ])
      await indexer.getBatchWritePromise()
      let tokens: array<token> = await indexer.query("Token")
      let message = value =>
        `Invalid Address "${value}" set on Token.id. An Address is kept here as its 20 bytes, so it must be 0x followed by 40 lowercase hex characters.`
      let expects = "an Address kept as its 20 bytes: 0x followed by 40 lowercase hex characters"
      t.expect((refused.contents, lookedUp.contents, tokens)).toEqual((
        [
          message("0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"),
          message("0x2b2f78c5bf6d9c12ee1225d5f374aa91204580"),
          message("2b2f78c5bf6d9c12ee1225d5f374aa91204580c3"),
          message("0x2b2f78c5bf6d9c12ee1225d5f374aa91204580zz"),
        ],
        [
          `Invalid Address "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3" passed to context.Token.get. An Address is kept here as its 20 bytes, so it must be 0x followed by 40 lowercase hex characters.`,
          `Invalid value passed to context.Token.getWhere({ owner: { _eq: ... } }). The field "owner" expects ${expects}.`,
          `Invalid value passed to context.Token.getWhere({ owner: { _in: ... } }). The field "owner" expects ${expects}. The value is at index 1 of the _in array.`,
        ],
        [],
      ))
    },
  )

  Scenario.make(
    ~supervised=false,
    ~schema,
    ~configYaml=configYaml(~addressFormat="lowercase", ~rollback=true),
  )->Scenario.it(
    "restores and removes bytea-kept Address ids on a reorg",
    ~sources=[{chain: 1, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      let restored = {
        id: "0x00000000000000000000000000000000000000aa",
        owner: "0x0000000000000000000000000000000000000001",
        optOwner: None,
        owners: [],
      }
      let removed = {...restored, id: "0x00000000000000000000000000000000000000bb"}
      await Scenario.enterReorgThreshold(~indexer, ~source, ~fromBlock=0)
      await source.expectItemsQueries([
        {
          fromBlock: 101,
          reply: Respond({
            items: [tokenItem(~block=101, async context => context.token.set(restored))],
            latestFetchedBlockNumber: 101,
            latestFetchedBlockHash: "0x0101",
          }),
        },
      ])
      await indexer.getBatchWritePromise()
      await source.expectItemsQueries([
        {
          fromBlock: 102,
          reply: Respond({
            items: [
              tokenItem(
                ~block=102,
                async context => {
                  context.token.set(removed)
                  context.token.deleteUnsafe(restored.id)
                },
              ),
            ],
            latestFetchedBlockNumber: 102,
            latestFetchedBlockHash: "0x0102",
          }),
        },
      ])
      await indexer.getBatchWritePromise()
      let beforeReorg: array<token> = await indexer.query("Token")

      await source.expectItemsQueries([
        {
          coversBlock: 103,
          reply: Respond({
            items: [],
            prevRangeLastBlock: {blockNumber: 102, blockHash: "0x102a"},
          }),
        },
        {partitionId: "0", reply: LeavePending},
      ])
      await source.expectBlockHashLookup({
        blockNumbers: [100, 101],
        reply: [
          {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
          {blockNumber: 101, blockHash: "0x0101", blockTimestamp: 101},
        ],
      })
      await indexer.getRollbackReadyPromise()
      await source.expectItemsQueries([
        {
          coversBlock: 102,
          reply: Respond({
            items: [],
            latestFetchedBlockNumber: 102,
            latestFetchedBlockHash: "0x0102",
          }),
        },
      ])
      await indexer.getBatchWritePromise()
      await indexer.waitUntilIdle()
      let afterReorg: array<token> = await indexer.query("Token")
      await indexer.stop()

      t.expect((beforeReorg, afterReorg)).toEqual(([removed], [restored]))
    },
  )
})
