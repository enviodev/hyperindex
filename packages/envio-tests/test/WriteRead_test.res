open Vitest

@send external padStart: (string, ~padCount: int, ~padChar: string) => string = "padStart"

let mockDate = (~year=2024, ~month=1, ~day=1) => {
  let padInt = i => i->Int.toString->padStart(~padCount=2, ~padChar="0")
  Date.fromString(`${year->padInt}-${month->padInt}-${day->padInt}T00:00:00Z`)
}

let scenario = Scenario.make(
  ~configYaml=`
name: write-read
save_full_history: true
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
enum AccountType {
  ADMIN
  USER
}

type User {
  id: ID!
  address: Bytes!
  updatesCountOnUserForTesting: Int!
  tokens: [Token!]! @derivedFrom(field: "owner")
  accountType: AccountType!
}

type NftCollection {
  id: ID!
  contractAddress: Bytes!
  name: String!
  symbol: String!
  maxSupply: BigInt!
  currentSupply: Int!
  tokens: [Token!]! @derivedFrom(field: "collection")
}

type Token {
  id: ID!
  tokenId: BigInt! @index
  collection: NftCollection! @index
  owner: User!
}

type SimpleEntity {
  id: ID!
  value: String!
}

type EntityWith63LenghtName______________________________________one {
  id: ID!
}

type EntityWith63LenghtName______________________________________two {
  id: ID!
}

type EntityWithAllTypes {
  id: ID!
  string: String!
  optString: String
  arrayOfStrings: [String!]!
  int_: Int!
  optInt: Int
  arrayOfInts: [Int!]!
  float_: Float!
  optFloat: Float
  arrayOfFloats: [Float!]!
  bool: Boolean!
  optBool: Boolean
  bigInt: BigInt!
  optBigInt: BigInt
  arrayOfBigInts: [BigInt!]!
  bigDecimal: BigDecimal!
  optBigDecimal: BigDecimal
  bigDecimalWithConfig: BigDecimal! @config(precision: 10, scale: 8)
  arrayOfBigDecimals: [BigDecimal!]!
  timestamp: Timestamp!
  optTimestamp: Timestamp
  json: Json!
  enumField: AccountType!
  optEnumField: AccountType
}

type EntityWithAllNonArrayTypes {
  id: ID!
  string: String!
  optString: String
  int_: Int!
  optInt: Int
  float_: Float!
  optFloat: Float
  bool: Boolean!
  optBool: Boolean
  bigInt: BigInt!
  optBigInt: BigInt
  bigDecimal: BigDecimal!
  optBigDecimal: BigDecimal
  bigDecimalWithConfig: BigDecimal! @config(precision: 10, scale: 8)
  enumField: AccountType!
  optEnumField: AccountType
  timestamp: Timestamp!
  optTimestamp: Timestamp
}
`,
)

// The entity records the schema above generates for a user, restated here: a
// scenario's handlers are ReScript, so nothing hands them a typed context.
type entityWithAllTypes = {
  id: string,
  string: string,
  optString: option<string>,
  arrayOfStrings: array<string>,
  int_: int,
  optInt: option<int>,
  arrayOfInts: array<int>,
  float_: float,
  optFloat: option<float>,
  arrayOfFloats: array<float>,
  bool: bool,
  optBool: option<bool>,
  bigInt: bigint,
  optBigInt: option<bigint>,
  arrayOfBigInts: array<bigint>,
  bigDecimal: BigDecimal.t,
  optBigDecimal: option<BigDecimal.t>,
  bigDecimalWithConfig: BigDecimal.t,
  arrayOfBigDecimals: array<BigDecimal.t>,
  timestamp: Date.t,
  optTimestamp: option<Date.t>,
  json: JSON.t,
  enumField: string,
  optEnumField: option<string>,
}

type entityWithAllNonArrayTypes = {
  id: string,
  string: string,
  optString: option<string>,
  int_: int,
  optInt: option<int>,
  float_: float,
  optFloat: option<float>,
  bool: bool,
  optBool: option<bool>,
  bigInt: bigint,
  optBigInt: option<bigint>,
  bigDecimal: BigDecimal.t,
  optBigDecimal: option<BigDecimal.t>,
  bigDecimalWithConfig: BigDecimal.t,
  enumField: string,
  optEnumField: option<string>,
  timestamp: Date.t,
  optTimestamp: option<Date.t>,
}

type idOnly = {id: string}
type simpleEntity = {id: string, value: string}
type user = {
  id: string,
  address: Address.t,
  updatesCountOnUserForTesting: int,
  accountType: string,
}
type nftCollection = {
  id: string,
  contractAddress: Address.t,
  name: string,
  symbol: string,
  maxSupply: bigint,
  currentSupply: int,
}
type token = {id: string, tokenId: bigint, collection_id: string, owner_id: string}

// A linked entity's filter key is the column, `owner_id` — the generated filter
// type carries the same `@as`, so ReScript source reads `owner` either way.
type tokenFilter = {
  @as("owner_id") owner?: Envio.whereOperator<string>,
  @as("tokenId") tokenId?: Envio.whereOperator<bigint>,
}

type setOnly<'entity> = {set: 'entity => unit}
type entityOps<'entity, 'filter> = {
  set: 'entity => unit,
  get: string => promise<option<'entity>>,
  deleteUnsafe: string => unit,
  getWhere: 'filter => promise<array<'entity>>,
}

type writeContext = {
  @as("EntityWithAllTypes") entityWithAllTypes: setOnly<entityWithAllTypes>,
  @as("EntityWithAllNonArrayTypes") entityWithAllNonArrayTypes: setOnly<entityWithAllNonArrayTypes>,
  @as("EntityWith63LenghtName______________________________________one")
  longNameOne: setOnly<idOnly>,
  @as("EntityWith63LenghtName______________________________________two")
  longNameTwo: setOnly<idOnly>,
}

type simpleContext = {
  @as("SimpleEntity") simpleEntity: entityOps<simpleEntity, unknown>,
}

type tokenContext = {
  @as("User") user: setOnly<user>,
  @as("NftCollection") nftCollection: setOnly<nftCollection>,
  @as("Token") token: entityOps<token, tokenFilter>,
}

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow]

// Head 300 against maxReorgDepth 200: one query opens at block 1, and its
// response is what every case below rides in on.
let reachFirstQuery = async (~t: Vitest.testContext, ~source: MockSource.t) => {
  await Utils.delay(0)
  t.expect(
    source.getHeightOrThrowCalls->Array.length,
    ~message="should have called getHeightOrThrow to get initial height",
  ).toEqual(1)
  source.resolveGetHeightOrThrow(300)
  await Utils.delay(0)
  await Utils.delay(0)
}

describe("Write/read tests", () => {
  scenario->Scenario.it(
    "Test writing and reading entities with special cases",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await reachFirstQuery(~t, ~source)

      let entityWithAllTypes = {
        id: "1",
        string: "string",
        optString: Some("optString"),
        arrayOfStrings: ["arrayOfStrings1", "arrayOfStrings2"],
        int_: 1,
        optInt: Some(2),
        arrayOfInts: [3, 4],
        float_: 1.1,
        optFloat: Some(2.2),
        arrayOfFloats: [3.3, 4.4],
        bool: true,
        optBool: Some(false),
        bigInt: BigInt.fromInt(1),
        optBigInt: Some(BigInt.fromInt(2)),
        arrayOfBigInts: [BigInt.fromInt(3), BigInt.fromInt(4)],
        bigDecimal: BigDecimal.fromStringUnsafe("1.1"),
        optBigDecimal: Some(BigDecimal.fromStringUnsafe("2.2")),
        bigDecimalWithConfig: BigDecimal.fromStringUnsafe("1.1"),
        arrayOfBigDecimals: [
          BigDecimal.fromStringUnsafe("3.3"),
          BigDecimal.fromStringUnsafe("4.4"),
        ],
        timestamp: mockDate(~day=1),
        optTimestamp: Some(mockDate(~day=2)),
        json: %raw(`{"foo": ["bar"]}`),
        enumField: "ADMIN",
        optEnumField: Some("ADMIN"),
      }
      let entityWithAllNonArrayTypes = {
        id: "1",
        string: "string",
        optString: Some("optString"),
        int_: 1,
        optInt: Some(2),
        float_: 1.1,
        optFloat: Some(2.2),
        bool: true,
        optBool: Some(false),
        bigInt: BigInt.fromInt(1),
        optBigInt: Some(BigInt.fromInt(2)),
        bigDecimal: BigDecimal.fromStringUnsafe("1.1"),
        optBigDecimal: Some(BigDecimal.fromStringUnsafe("2.2")),
        bigDecimalWithConfig: BigDecimal.fromStringUnsafe("1.1"),
        enumField: "ADMIN",
        optEnumField: Some("ADMIN"),
        timestamp: mockDate(~day=1),
        optTimestamp: Some(mockDate(~day=2)),
      }

      source.resolveGetItemsOrThrow([
        {
          blockNumber: 50,
          logIndex: 1,
          handler: async args => {
            let context = args.context->(Utils.magic: Internal.handlerContext => writeContext)
            context.entityWithAllTypes.set(entityWithAllTypes)
            context.entityWithAllNonArrayTypes.set(entityWithAllNonArrayTypes)

            // Entity names at the length limit: their history tables have to be
            // truncated to something Postgres accepts, and still be writable.
            context.longNameOne.set({id: "1"})
            context.longNameTwo.set({id: "2"})
          },
        },
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        await (indexer.query("EntityWithAllTypes"): promise<array<entityWithAllTypes>>),
      ).toEqual([entityWithAllTypes])
      t.expect(
        await (
          indexer.queryHistory("EntityWithAllTypes"): promise<array<Change.t<entityWithAllTypes>>>
        ),
      ).toEqual([
        Set({
          checkpointId: 1n,
          entityId: "1"->EntityId.unsafeOfString,
          entity: entityWithAllTypes,
        }),
      ])

      t.expect(
        await (
          indexer.query("EntityWithAllNonArrayTypes"): promise<array<entityWithAllNonArrayTypes>>
        ),
      ).toEqual([entityWithAllNonArrayTypes])
      t.expect(
        await (
          indexer.queryHistory("EntityWithAllNonArrayTypes"): promise<
            array<Change.t<entityWithAllNonArrayTypes>>,
          >
        ),
      ).toEqual([
        Set({
          checkpointId: 1n,
          entityId: "1"->EntityId.unsafeOfString,
          entity: entityWithAllNonArrayTypes,
        }),
      ])

      t.expect(
        await (
          indexer.query("EntityWith63LenghtName______________________________________one"): promise<
            array<idOnly>,
          >
        ),
      ).toEqual([{id: "1"}])
      t.expect(
        await (
          indexer.queryHistory(
            "EntityWith63LenghtName______________________________________one",
          ): promise<array<Change.t<idOnly>>>
        ),
      ).toEqual([
        Set({checkpointId: 1n, entityId: "1"->EntityId.unsafeOfString, entity: {id: "1"}}),
      ])
      t.expect(
        await (
          indexer.query("EntityWith63LenghtName______________________________________two"): promise<
            array<idOnly>,
          >
        ),
      ).toEqual([{id: "2"}])
      t.expect(
        await (
          indexer.queryHistory(
            "EntityWith63LenghtName______________________________________two",
          ): promise<array<Change.t<idOnly>>>
        ),
      ).toEqual([
        Set({checkpointId: 1n, entityId: "2"->EntityId.unsafeOfString, entity: {id: "2"}}),
      ])
    },
  )

  scenario->Scenario.it(
    "Keeps committed entities across batches without rewriting their history",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await reachFirstQuery(~t, ~source)

      source.resolveGetItemsOrThrow([
        {
          blockNumber: 50,
          logIndex: 1,
          handler: async args => {
            let context = args.context->(Utils.magic: Internal.handlerContext => simpleContext)
            context.simpleEntity.set({id: "untouched", value: "batch1"})
            context.simpleEntity.set({id: "updated", value: "batch1"})
          },
        },
      ])
      await indexer.getBatchWritePromise()

      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow([
        {
          blockNumber: 51,
          logIndex: 1,
          handler: async args => {
            let context = args.context->(Utils.magic: Internal.handlerContext => simpleContext)
            // "untouched" is carried over from the previous batch and read from
            // the in-memory store without hitting the db.
            let untouched = await context.simpleEntity.get("untouched")
            t.expect(untouched).toEqual(Some({id: "untouched", value: "batch1"}))
            context.simpleEntity.set({id: "updated", value: "batch2"})
          },
        },
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        await (indexer.queryHistory("SimpleEntity"): promise<array<Change.t<simpleEntity>>>),
      ).toEqual([
        Set({
          checkpointId: 1n,
          entityId: "untouched"->EntityId.unsafeOfString,
          entity: {id: "untouched", value: "batch1"},
        }),
        Set({
          checkpointId: 1n,
          entityId: "updated"->EntityId.unsafeOfString,
          entity: {id: "updated", value: "batch1"},
        }),
        Set({
          checkpointId: 3n,
          entityId: "updated"->EntityId.unsafeOfString,
          entity: {id: "updated", value: "batch2"},
        }),
      ])
    },
  )

  it("dropCommittedChanges keeps only uncommitted changes (checkpointId > committed)", t => {
    let makeEntity = (id): Internal.entity =>
      {"id": id}->(Utils.magic: {"id": string} => Internal.entity)

    let table = InMemoryTable.Entity.make()
    let add = (id, checkpointId) =>
      table->InMemoryTable.Entity.set(
        ~committedCheckpointId=Internal.initialCheckpointId,
        Set({entityId: id->EntityId.unsafeOfString, entity: makeEntity(id), checkpointId}),
      )
    add("loaded", Internal.loadedFromDbCheckpointId)
    add("committed", 5n)
    add("uncommitted", 6n)

    table->InMemoryTable.Entity.dropCommittedChanges(
      ~committedCheckpointId=5n,
      ~keepLoadedFromDb=false,
    )

    t.expect((
      table.changesCount,
      table.latestEntityChangeById->Dict.keysToArray->Array.toSorted(String.compare),
    )).toEqual((1., ["uncommitted"]))
  })

  it("dropCommittedChanges with keepLoadedFromDb spares db-loaded entries", t => {
    let makeEntity = (id): Internal.entity =>
      {"id": id}->(Utils.magic: {"id": string} => Internal.entity)

    let table = InMemoryTable.Entity.make()
    let add = (id, checkpointId) =>
      table->InMemoryTable.Entity.set(
        ~committedCheckpointId=Internal.initialCheckpointId,
        Set({entityId: id->EntityId.unsafeOfString, entity: makeEntity(id), checkpointId}),
      )
    add("loaded", Internal.loadedFromDbCheckpointId)
    add("committed", 5n)
    add("uncommitted", 6n)

    table->InMemoryTable.Entity.dropCommittedChanges(
      ~committedCheckpointId=5n,
      ~keepLoadedFromDb=true,
    )

    t.expect((
      table.changesCount,
      table.latestEntityChangeById->Dict.keysToArray->Array.toSorted(String.compare),
    )).toEqual((2., ["loaded", "uncommitted"]))
  })

  scenario->Scenario.it(
    "Test getWhere queries with eq and gt operators",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await reachFirstQuery(~t, ~source)

      let results = Dict.make()
      let record = (name, tokens: array<token>) => results->Dict.set(name, tokens->Array.length)

      let testUserId = "test-user-1"
      let testCollectionId = "test-collection-1"

      source.resolveGetItemsOrThrow([
        {
          blockNumber: 50,
          logIndex: 1,
          handler: async args => {
            let context = args.context->(Utils.magic: Internal.handlerContext => tokenContext)

            context.user.set({
              id: testUserId,
              address: "0x1234567890123456789012345678901234567890"->Utils.magic,
              updatesCountOnUserForTesting: 0,
              accountType: "USER",
            })

            context.nftCollection.set({
              id: testCollectionId,
              contractAddress: "0xabcdef0123456789abcdef0123456789abcdef01"->Utils.magic,
              name: "Test Collection",
              symbol: "TEST",
              maxSupply: BigInt.fromInt(100),
              currentSupply: 1,
            })

            context.token.set({
              id: "token-1",
              tokenId: BigInt.fromInt(50),
              collection_id: testCollectionId,
              owner_id: testUserId,
            })
            context.token.set({
              id: "token-2",
              tokenId: BigInt.fromInt(60),
              collection_id: testCollectionId,
              owner_id: testUserId,
            })

            record("eqOwner", await context.token.getWhere({owner: {_eq: testUserId}}))
            record("eqTokenId", await context.token.getWhere({tokenId: {_eq: BigInt.fromInt(50)}}))
            record("gt50", await context.token.getWhere({tokenId: {_gt: BigInt.fromInt(50)}}))
            record("gt49", await context.token.getWhere({tokenId: {_gt: BigInt.fromInt(49)}}))
            record("lt50", await context.token.getWhere({tokenId: {_lt: BigInt.fromInt(50)}}))
            record("lt51", await context.token.getWhere({tokenId: {_lt: BigInt.fromInt(51)}}))
            record("gte50", await context.token.getWhere({tokenId: {_gte: BigInt.fromInt(50)}}))
            record("gte51", await context.token.getWhere({tokenId: {_gte: BigInt.fromInt(51)}}))
            record("lte50", await context.token.getWhere({tokenId: {_lte: BigInt.fromInt(50)}}))
            record("lte49", await context.token.getWhere({tokenId: {_lte: BigInt.fromInt(49)}}))
            record(
              "inOwner",
              await context.token.getWhere({owner: {_in: [testUserId, "non-existent-user"]}}),
            )
            record(
              "inTokenId",
              await context.token.getWhere({
                tokenId: {_in: [BigInt.fromInt(50), BigInt.fromInt(60)]},
              }),
            )
            record(
              "inTokenIdNoMatch",
              await context.token.getWhere({tokenId: {_in: [BigInt.fromInt(999)]}}),
            )
            record("inTokenIdEmpty", await context.token.getWhere({tokenId: {_in: []}}))
          },
        },
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        results,
        ~message="every comparison operator narrows the two tokens (ids 50 and 60) as written",
      ).toEqual(
        Dict.fromArray([
          ("eqOwner", 2),
          ("eqTokenId", 1),
          ("gt50", 1),
          ("gt49", 2),
          ("lt50", 0),
          ("lt51", 1),
          ("gte50", 2),
          ("gte51", 1),
          ("lte50", 1),
          ("lte49", 0),
          ("inOwner", 2),
          ("inTokenId", 2),
          ("inTokenIdNoMatch", 0),
          ("inTokenIdEmpty", 0),
        ]),
      )

      // Deleting a token has to drop it from the index the getWhere above built.
      let afterDelete = ref(-1)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow([
        {
          blockNumber: 51,
          logIndex: 1,
          handler: async args => {
            let context = args.context->(Utils.magic: Internal.handlerContext => tokenContext)
            context.token.deleteUnsafe("token-1")
            let remaining = await context.token.getWhere({owner: {_eq: testUserId}})
            afterDelete := remaining->Array.length
          },
        },
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        afterDelete.contents,
        ~message="should have removed index on deleted token, leaving one token",
      ).toBe(1)
    },
  )

  scenario->Scenario.it(
    "getWhere throws a user friendly error for an invalid filter",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await reachFirstQuery(~t, ~source)

      let error = ref("")

      source.resolveGetItemsOrThrow([
        {
          blockNumber: 50,
          logIndex: 1,
          handler: async args => {
            let context = args.context->(Utils.magic: Internal.handlerContext => tokenContext)
            error := try {
                let _ = await context.token.getWhere(%raw(`{tokenId: undefined}`))
                "Expected getWhere to throw"
              } catch {
              | JsExn(e) => e->JsExn.message->Option.getOr("(no message)")
              }
          },
        },
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        error.contents,
      ).toEqual(`Invalid undefined value passed to context.Token.getWhere({ tokenId: undefined }). Filtering by null or undefined values is not supported in getWhere. Please provide an operator like { _eq: value }.`)
    },
  )
})
