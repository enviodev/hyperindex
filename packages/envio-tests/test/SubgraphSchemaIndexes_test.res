open Vitest

// A subgraph's Graph endpoint answers queries while it syncs, as graph-node's
// does. The schema's indexes waited for the backfill to finish, and relations
// had none of their own, so until then every nested selection and every
// `@derivedFrom` lookup scanned the whole table: ENS app queries took 1.3-5.7 s.
let {InternalTestIndexer.config: config} = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Registry
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Registry
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Domain
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: NewOwner(string,address)
          handler: handleNewOwner
      file: ./src/registry.ts
`,
  ~schema=`
type Domain @entity {
  id: ID!
  name: String
  parent: Domain
  subdomains: [Domain!]! @derivedFrom(field: "parent")
  registration: Registration @derivedFrom(field: "domain")
}

type Registration @entity {
  id: ID!
  domain: Domain!
  registrant: Account!
  cost: BigInt
}

type Account @entity {
  id: Bytes!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"NewOwner","anonymous":false,"inputs":[{"name":"name","type":"string","indexed":false},{"name":"owner","type":"address","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([("src/registry.ts", `export function handleNewOwner(): void {}`)]),
)

describe("A subgraph's schema indexes", () => {
  Async.it("Exist on every relation as soon as the tables do", async t => {
    let pgSchema = TestPgSchema.make()
    let logger = Logger.makeInMemory()
    let storage = Storage.makeStorageFromEnv(~config, ~logger, ~pgSchema, ~isHasuraEnabled=false)
    let sql = Storage.clientFromEnv(~config, ~logger, ~pgSchema, ~isHasuraEnabled=false)
    let _ = await storage.initialize(
      ~chainConfigs=config.chainMap->ChainMap.values,
      ~contractMapping=config.contractMapping,
      ~entities=config.userEntities,
      ~enums=config.allEnums,
      ~envioInfo=JSON.Encode.object(Dict.make()),
    )
    let indexes = await sql->PgCatalog.indexes(~pgSchema)
    await sql->TestPgSchema.drop(~pgSchema)
    await storage.close()
    await sql->StorageClient.close

    t.expect(
      indexes
      ->Array.filter(
        index =>
          ["Domain", "Registration", "Account"]->Array.includes(index.tableName) && !index.isUnique,
      )
      ->Array.map(index => `${index.tableName}(${index.columns->Array.join(",")})`)
      ->Array.toSorted(String.compare),
    ).toEqual(["Domain(parent_id)", "Registration(domain_id)", "Registration(registrant_id)"])
  })
})
