open Vitest

let expectParseError = (t, ~schema=?, ~env=?, ~files=?, yaml, message) =>
  t.expect(
    () => InternalTestIndexer.fromUserApi(~schema?, ~env?, ~files?, ~configYaml=yaml)->ignore,
  ).toThrowError(
    message,
  )

let parseAddressConfig = (~addressFormat="checksum", ~contractName="ERC20", address): Config.t =>
  InternalTestIndexer.fromUserApi(~configYaml=`
name: address-config
address_format: ${addressFormat}
contracts:
  - name: ${contractName}
    events:
      - event: Transfer()
chains:
  - id: 1
    rpc:
      url: https://eth.com
      for: sync
    start_block: 0
    contracts:
      - name: ${contractName}
        address: "${address}"
`).config

let firstContract = (config: Config.t): Config.contract => {
  let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
  chain.contracts->Array.getUnsafe(0)
}

describe("InternalTestIndexer.fromUserApi", () => {
  it("parses user YAML with explicit env and no project schema", t => {
    let env = Dict.fromArray([
      ("RPC_URL", "https://rpc.example.test"),
      ("START_BLOCK", "42"),
    ])

    let {config} = InternalTestIndexer.fromUserApi(
      ~env,
      ~configYaml=`
name: in-memory
chains:
  - id: 1
    rpc:
      url: \${RPC_URL}
      for: sync
    start_block: \${START_BLOCK}
`,
    )

    let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
    t.expect(config.name).toBe("in-memory")
    t.expect(config.userEntities->Array.length).toBe(0)
    t.expect(chain.startBlock).toBe(42)

    switch chain.sourceConfig {
    | Config.EvmSourceConfig({rpcs}) => {
        let rpc = rpcs->Array.getUnsafe(0)
        t.expect(rpc.url).toBe("https://rpc.example.test")
      }
    | _ => t.expect("unexpected source").toBe("EVM RPC source")
    }
  })

  it("resolves ABI paths from caller-provided virtual files", t => {
    let files = Dict.fromArray([
      (
        "abis/token.json",
        `[{"type":"event","name":"Transfer","inputs":[],"anonymous":false}]`,
      ),
    ])

    let {config} = InternalTestIndexer.fromUserApi(
      ~files,
      ~configYaml=`
name: virtual-abi
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        abi_file_path: abis/token.json
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer
`,
    )

    let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
    let contract = chain.contracts->Array.getUnsafe(0)
    let event = contract.events->Array.getUnsafe(0)
    t.expect(contract.events->Array.length).toBe(1)
    t.expect(event.name).toBe("Transfer")
  })
})

describe("EVM config YAML", () => {
  [("greeter", "Greeter"), ("Greeter", "Greeter")]->Array.forEach(
    ((inputName, expectedName)) => {
      it(`normalizes contract name ${inputName}`, t => {
        let contract =
          parseAddressConfig(
            ~contractName=inputName,
            "0x0000000000000000000000000000000000000001",
          )->firstContract
        t.expect(contract.name).toBe(expectedName)
      })
    },
  )

  it("preserves a full 20-byte address through the complete YAML pipeline", t => {
    let address = "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
    let contract = parseAddressConfig(address)->firstContract
    let parsed = contract.addresses->Array.getUnsafe(0)
    t.expect(parsed->Address.toString).toBe(address)
  })

  [
    ("checksum", "0xa2f6e6029638ccb484a2ccb6414499ad3e825cac"),
    ("checksum", "0xA2F6E6029638CCB484A2CCB6414499AD3E825CAC"),
    ("lowercase", "0xa2f6e6029638ccb484a2ccb6414499ad3e825cac"),
    ("lowercase", "0xA2F6E6029638CCB484A2CCB6414499AD3E825CAC"),
  ]->Array.forEach(((addressFormat, address)) => {
    it(`normalizes ${address} with address_format: ${addressFormat}`, t => {
      let contract = parseAddressConfig(~addressFormat, address)->firstContract
      let parsed = contract.addresses->Array.getUnsafe(0)
      t.expect(parsed->Address.toString).toBe(
        switch addressFormat {
        | "lowercase" => "0xa2f6e6029638ccb484a2ccb6414499ad3e825cac"
        | _ => "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"
        },
      )
    })
  })

  ["checksum", "lowercase"]->Array.forEach(addressFormat => {
    it(`rejects invalid addresses with address_format: ${addressFormat}`, t => {
      t.expect(() => parseAddressConfig(~addressFormat, "0xfoo")->ignore).toThrowError(
        `Contract "ERC20" on chain 1 has invalid address "0xfoo"`,
      )
    })
  })

  it("rejects one address assigned to two contracts on the same chain", t => {
    expectParseError(
      t,
      `
name: duplicate-address
contracts:
  - name: AaveToken
    events:
      - event: Transfer()
  - name: AaveV3
    events:
      - event: DelegateChanged()
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: AaveToken
        address: "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9"
      - name: AaveV3
        address: "0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9"
`,
      "configured for multiple contracts: AaveToken and AaveV3",
    )
  })

  it("rejects an address listed twice for one contract", t => {
    expectParseError(
      t,
      `
name: duplicate-address
contracts:
  - name: AaveToken
    events:
      - event: Transfer()
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: AaveToken
        address:
          - "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9"
          - "0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9"
`,
      "is listed multiple times for the contract AaveToken on chain 1",
    )
  })

  it("allows the same address on different chains", t => {
    let {config} = InternalTestIndexer.fromUserApi(~configYaml=`
name: multichain-address
contracts:
  - name: AaveToken
    events:
      - event: Transfer()
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: AaveToken
        address: "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9"
  - id: 137
    start_block: 0
    contracts:
      - name: AaveToken
        address: "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9"
`)
    t.expect(config.chainMap->ChainMap.values->Array.length).toBe(2)
  })

  it("parses entity and field descriptions from schema text", t => {
    let {config} = InternalTestIndexer.fromUserApi(
      ~schema=`
"""A user of the protocol"""
type User {
  """The user's address"""
  id: ID!
  balance: BigInt!
  """Tokens owned by this user"""
  tokens: [Token!]! @derivedFrom(field: "owner")
}

type Token {
  id: ID!
  owner: User!
}
`,
      ~configYaml=`
name: descriptions
chains:
  - id: 1
    start_block: 0
`,
    )
    let user = config.userEntitiesByName->Dict.getUnsafe("User")
    t.expect({
      "entity": user.table.description,
      "id": switch user.table.fields->Array.getUnsafe(0) {
      | Table.Field(field) => field.description
      | _ => None
      },
      "derived": switch user.table.fields->Array.getUnsafe(2) {
      | Table.DerivedFrom(field) => field.description
      | _ => None
      },
    }).toEqual({
      "entity": Some("A user of the protocol"),
      "id": Some("The user's address"),
      "derived": Some("Tokens owned by this user"),
    })
  })

  it("resolves entity storage directives and config defaults together", t => {
    let {config} = InternalTestIndexer.fromUserApi(
      ~schema=`
type User { id: ID! }
type Snapshot @storage(clickhouse: true) { id: ID! }
`,
      ~configYaml=`
name: storage-routing
storage:
  postgres:
    default: true
  clickhouse:
    default: true
chains:
  - id: 1
    start_block: 0
`,
    )
    let user = config.userEntitiesByName->Dict.getUnsafe("User")
    let snapshot = config.userEntitiesByName->Dict.getUnsafe("Snapshot")
    t.expect((user.storage, snapshot.storage)).toEqual((
      {Internal.postgres: true, clickhouse: true},
      {Internal.postgres: false, clickhouse: true},
    ))
  })

  it("preserves per-backend column names across the public config boundary", t => {
    let {config} = InternalTestIndexer.fromUserApi(
      ~schema=`
type User {
  id: ID!
  userId: BigInt!
}
`,
      ~configYaml=`
name: column-names
storage:
  postgres:
    default: true
    column_name_format: snake_case
  clickhouse:
    default: true
    column_name_format: original
chains:
  - id: 1
    start_block: 0
`,
    )
    let user = config.userEntitiesByName->Dict.getUnsafe("User")
    let columnNames = switch user.table.fields->Array.getUnsafe(1) {
    | Table.Field(field) => (field.postgresDbName, field.clickhouseDbName)
    | _ => (None, None)
    }
    t.expect(columnNames).toEqual((Some("user_id"), None))
  })
})

describe("config YAML interpolation errors", () => {
  it("reports missing variables from the explicit env map", t => {
    expectParseError(
      t,
      `
name: missing-env
chains:
  - id: 1
    rpc:
      url: \${MISSING_RPC_URL}
      for: sync
    start_block: 0
`,
      "Environment variables are not present: MISSING_RPC_URL",
    )
  })

  it("reports invalid variable expressions", t => {
    expectParseError(
      t,
      `
name: invalid-env
chains:
  - id: 1
    rpc:
      url: \${My RPC URL}
      for: sync
    start_block: 0
`,
      `Invalid environment variables are present: "My RPC URL"`,
    )
  })

  it("reports unbalanced nested defaults", t => {
    expectParseError(
      t,
      `
name: invalid-env
chains:
  - id: 1
    rpc:
      url: \${MISSING:-\${FALLBACK}
      for: sync
    start_block: 0
`,
      "Unbalanced '${' expression",
    )
  })
})

describe("human config YAML errors", () => {
  [
    (
      "rejects malformed YAML",
      "name: [unterminated\n",
      "Failed to deserialize config",
    ),
    (
      "rejects a non-string ecosystem",
      `
name: wrong-ecosystem-type
ecosystem: {}
chains: []
`,
      `the "ecosystem" field is not a string`,
    ),
    (
      "rejects an unsupported ecosystem",
      `
name: unsupported
ecosystem: cosmos
chains: []
`,
      `The ecosystem "cosmos" is not supported`,
    ),
    (
      "rejects unknown storage backends",
      `
name: unknown-storage
storage:
  postgres: true
  bigquery: true
chains:
  - id: 1
    start_block: 0
`,
      "unknown field `bigquery`",
    ),
    (
      "rejects unknown storage options",
      `
name: typo
storage:
  postgres: true
  clickhouse:
    defautl: true
chains:
  - id: 1
    start_block: 0
`,
      "unknown field `defautl`",
    ),
    (
      "rejects invalid column name formats",
      `
name: invalid-column-format
storage:
  postgres:
    column_name_format: kebab-case
chains:
  - id: 1
    start_block: 0
`,
      "unknown variant `kebab-case`",
    ),
    (
      "rejects a storage backend with the wrong value shape",
      `
name: invalid-storage-shape
storage:
  clickhouse: enabled
chains:
  - id: 1
    start_block: 0
`,
      "expected a boolean or an options object",
    ),
    (
      "rejects numeric separators instead of silently treating them as numbers",
      `
name: numeric-separator
chains:
  - id: 1
    start_block: 1_000
`,
      `invalid type: string "1_000", expected u64`,
    ),
    (
      "rejects unknown SVM program fields",
      `
name: unknown-svm-field
ecosystem: svm
chains:
  - start_block: 1
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: Program
          program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
          bogus_extra: true
          instructions: []
`,
      "unknown field `bogus_extra`",
    ),
  ]->Array.forEach(((name, yaml, message)) => {
    it(name, t => expectParseError(t, yaml, message))
  })
})

describe("system config validation errors", () => {
  it("preserves the root cause from nested Rust error contexts", t => {
    expectParseError(
      t,
      `
name: missing-abi
contracts:
  - name: Token
    events:
      - event: Transfer
chains:
  - id: 1
    start_block: 0
`,
      "No abi file provided for event Transfer",
    )
  })

  it("rejects invalid Solidity types in inline event signatures", t => {
    expectParseError(
      t,
      `
name: invalid-event-type
contracts:
  - name: Token
    events:
      - event: MyEvent(uint69 value)
chains:
  - id: 1
    start_block: 0
`,
      "uint69",
    )
  })

  [
    (
      "rejects ClickHouse without Postgres",
      `
name: clickhouse-only
storage:
  clickhouse: true
chains:
  - id: 1
    start_block: 0
`,
      "ClickHouse is not supported as a single storage yet",
    ),
    (
      "rejects a config with every storage disabled",
      `
name: no-storage
storage:
  postgres: false
  clickhouse: false
chains:
  - id: 1
    start_block: 0
`,
      "At least one storage backend must be enabled",
    ),
    (
      "rejects end_block before start_block",
      `
name: invalid-block-range
chains:
  - id: 1
    start_block: 20
    end_block: 10
`,
      "end_block smaller than start_block",
    ),
    (
      "rejects two historical sync sources",
      `
name: duplicate-sync-source
chains:
  - id: 1
    hypersync_config:
      url: https://eth.hypersync.xyz
    rpc:
      url: https://eth.example.test
      for: sync
    start_block: 0
`,
      "Cannot define both hypersync_config and rpc as a data-source for historical sync",
    ),
    (
      "rejects RPC URLs with a non-HTTP protocol",
      `
name: invalid-rpc-url
chains:
  - id: 999999
    rpc:
      url: ftp://rpc.example.test
      for: sync
    start_block: 0
`,
      "The RPC url \"ftp://rpc.example.test\" is incorrect format",
    ),
    (
      "rejects WebSocket URLs with a non-WebSocket protocol",
      `
name: invalid-websocket-url
chains:
  - id: 999999
    rpc:
      url: https://rpc.example.test
      ws: https://rpc.example.test/ws
      for: sync
    start_block: 0
`,
      "Expected wss:// or ws:// protocol",
    ),
    (
      "rejects HyperSync URLs with a non-HTTP protocol",
      `
name: invalid-hypersync-url
chains:
  - id: 999999
    hypersync_config:
      url: ftp://hypersync.example.test
    start_block: 0
`,
      "The HyperSync URL \"ftp://hypersync.example.test\" is in incorrect format",
    ),
    (
      "rejects unknown chains without an explicit sync source",
      `
name: missing-evm-source
chains:
  - id: 999999
    start_block: 0
`,
      "Failed to automatically find HyperSync endpoint for the chain 999999",
    ),
    (
      "rejects duplicate transaction field selections",
      `
name: duplicate-transaction-fields
field_selection:
  transaction_fields: [hash, hash]
chains:
  - id: 1
    start_block: 0
`,
      "transaction_fields selection contains the following duplicates: hash",
    ),
    (
      "rejects duplicate block field selections",
      `
name: duplicate-block-fields
field_selection:
  block_fields: [parentHash, parentHash]
chains:
  - id: 1
    start_block: 0
`,
      "block_fields selection contains the following duplicates: parentHash",
    ),
    (
      "rejects transaction fields unavailable through RPC sync",
      `
name: unavailable-rpc-transaction-field
field_selection:
  transaction_fields: [gas]
chains:
  - id: 999999
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
`,
      "selected transaction_fields are unavailable for indexing via RPC: gas",
    ),
    (
      "rejects block fields unavailable through RPC sync",
      `
name: unavailable-rpc-block-field
field_selection:
  block_fields: [sha3Uncles]
chains:
  - id: 999999
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
`,
      "selected block_fields are unavailable for indexing via RPC: sha3Uncles",
    ),
    (
      "rejects event fields unavailable on a local RPC contract",
      `
name: unavailable-local-event-field
chains:
  - id: 999999
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        events:
          - event: Transfer()
            field_selection:
              transaction_fields: [gas]
`,
      "selected transaction_fields are unavailable for indexing via RPC: gas",
    ),
    (
      "rejects event fields unavailable on a global contract used by RPC",
      `
name: unavailable-global-event-field
contracts:
  - name: Token
    events:
      - event: Transfer()
        field_selection:
          transaction_fields: [gas]
chains:
  - id: 999999
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
`,
      "selected transaction_fields are unavailable for indexing via RPC: gas",
    ),
    (
      "rejects duplicate contract names case-insensitively",
      `
name: duplicate-contracts
contracts:
  - name: Token
    events:
      - event: Transfer()
  - name: token
    events:
      - event: Approval()
chains:
  - id: 1
    start_block: 0
`,
      "Duplicate contract names detected",
    ),
    (
      "rejects local contract references without a global definition",
      `
name: missing-global-contract
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Missing
        address: "0x0000000000000000000000000000000000000001"
`,
      "verify that the name reference is correct",
    ),
    (
      "rejects duplicate chain ids",
      `
name: duplicate-chain-id
chains:
  - id: 1
    start_block: 0
  - id: 1
    start_block: 100
`,
      "Failed inserting chain at chains map",
    ),
    (
      "rejects unsupported Fuel network ids without an explicit endpoint",
      `
name: unsupported-fuel-network
ecosystem: fuel
chains:
  - id: 42
    start_block: 0
`,
      "Fuel network id 42 is not supported",
    ),
    (
      "rejects contract names that are invalid identifiers",
      `
name: invalid-contract-name
contracts:
  - name: Has-Hyphen
    events:
      - event: Transfer()
chains:
  - id: 1
    start_block: 0
`,
      "invalid characters for contract names",
    ),
    (
      "rejects reserved contract names",
      `
name: reserved-contract-name
contracts:
  - name: module
    events:
      - event: Transfer()
chains:
  - id: 1
    start_block: 0
`,
      "reserved words for contract names",
    ),
    (
      "rejects configs where every chain is skipped",
      `
name: all-skipped
chains:
  - id: 1
    skip: true
    start_block: 0
  - id: 137
    skip: true
    start_block: 0
`,
      "All chains are skipped",
    ),
  ]->Array.forEach(((name, yaml, message)) => {
    it(name, t => expectParseError(t, yaml, message))
  })
})

describe("config YAML success cases", () => {
  it("parses a minimal Fuel config through the public boundary", t => {
    let {config} = InternalTestIndexer.fromUserApi(~configYaml=`
name: fuel-config
ecosystem: fuel
chains:
  - id: 0
    start_block: 7
`)
    let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
    t.expect(config.ecosystem.name).toEqual(Ecosystem.Fuel)
    t.expect((chain.id, chain.startBlock)).toEqual((0, 7))
  })

  it("parses a minimal SVM config through the public boundary", t => {
    let {config} = InternalTestIndexer.fromUserApi(~configYaml=`
name: svm-config
ecosystem: svm
chains:
  - rpc: https://solana.example.test
    start_block: 8
`)
    let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
    t.expect(config.ecosystem.name).toEqual(Ecosystem.Svm)
    t.expect((chain.id, chain.startBlock)).toEqual((0, 8))
  })

  it("validates event field selections against only the chain that uses them", t => {
    let {config} = InternalTestIndexer.fromUserApi(~configYaml=`
name: mixed-sync-sources
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: HyperOnly
        events:
          - event: Transfer()
            field_selection:
              transaction_fields: [gas]
  - id: 999999
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: RpcOnly
        events:
          - event: Ping()
`)
    t.expect(config.chainMap->ChainMap.values->Array.length).toBe(2)
  })

  it("allows a global contract with HyperSync-only fields when unrelated chains use RPC", t => {
    let {config} = InternalTestIndexer.fromUserApi(~configYaml=`
name: mixed-global-contract
contracts:
  - name: HyperOnly
    events:
      - event: Transfer()
        field_selection:
          transaction_fields: [gas]
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: HyperOnly
  - id: 999999
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
`)
    t.expect(config.chainMap->ChainMap.values->Array.length).toBe(2)
  })

  it("removes skipped chains from runtime config", t => {
    let {config} = InternalTestIndexer.fromUserApi(~configYaml=`
name: chain-options
chains:
  - id: 1
    skip: true
    start_block: 1000
  - id: 137
    start_block: 2000
`)
    let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
    t.expect(config.chainMap->ChainMap.values->Array.length).toBe(1)
    t.expect(chain.id).toBe(137)
    t.expect(chain.startBlock).toBe(2000)
  })

  it("normalizes trailing slashes in HyperSync URLs", t => {
    let {config} = InternalTestIndexer.fromUserApi(~configYaml=`
name: hypersync-url
chains:
  - id: 1
    hypersync_config:
      url: https://eth.hypersync.xyz//
    start_block: 0
`)
    let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
    switch chain.sourceConfig {
    | Config.EvmSourceConfig({hypersync: Some(url)}) =>
      t.expect(url).toBe("https://eth.hypersync.xyz")
    | _ => t.expect("unexpected source").toBe("EVM HyperSync source")
    }
  })

  it("parses nested Hardhat ABI objects from virtual files", t => {
    let files = Dict.fromArray([
      (
        "artifacts/Token.json",
        `{"contractName":"Token","abi":[{"type":"event","name":"Transfer","inputs":[],"anonymous":false}]}`,
      ),
    ])
    let {config} = InternalTestIndexer.fromUserApi(
      ~files,
      ~configYaml=`
name: nested-abi
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        abi_file_path: artifacts/Token.json
        events:
          - event: Transfer
`,
    )
    let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
    let contract = chain.contracts->Array.getUnsafe(0)
    let event = contract.events->Array.getUnsafe(0)
    t.expect(event.name).toBe("Transfer")
  })

  it("accepts user event signatures with prefixes, tuple spacing, and trailing semicolons", t => {
    let {config} = InternalTestIndexer.fromUserApi(~configYaml=`
name: event-signature-formatting
contracts:
  - name: Shop
    events:
      - event: event AddShopItems((uint128 ,uint16,uint16 ,uint16,uint16,bool)[] shopItems, uint256 indexed globalEventId);
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Shop
`)
    let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
    let contract = chain.contracts->Array.getUnsafe(0)
    let event = contract.events->Array.getUnsafe(0)
    t.expect(event.name).toBe("AddShopItems")
  })

  it("uses explicit schema text even when YAML names a nonexistent schema path", t => {
    let {config} = InternalTestIndexer.fromUserApi(
      ~schema=`type Token { id: ID! }`,
      ~configYaml=`
name: explicit-schema
schema: ./does-not-exist.graphql
chains:
  - id: 1
    start_block: 0
`,
    )
    t.expect(config.userEntitiesByName->Dict.has("Token")).toBe(true)
  })
})

describe("SVM config validation errors", () => {
  let prefix = `
name: svm-validation
ecosystem: svm
chains:
  - start_block: 0
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
`

  [
    (
      "rejects invalid program ids",
      prefix ++ `
        - name: Program
          program_id: not_a_pubkey
          instructions: []
`,
      "invalid program_id",
    ),
    (
      "rejects base58 program ids that do not decode to 32 bytes",
      prefix ++ `
        - name: Program
          program_id: 111111111111111111111111111111111
          instructions: []
`,
      "invalid program_id",
    ),
    (
      "rejects duplicate instruction names",
      prefix ++ `
        - name: Program
          program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
          instructions:
            - {name: Transfer, discriminator: "0x0f"}
            - {name: Transfer, discriminator: "0x21"}
`,
      "declares the instruction \"Transfer\" more than once",
    ),
    (
      "rejects invalid discriminators",
      prefix ++ `
        - name: Program
          program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
          instructions:
            - {name: Transfer, discriminator: "0x012"}
`,
      "must be 1, 2, 4, or 8 bytes",
    ),
    (
      "rejects account-filter positions outside the supported range",
      prefix ++ `
        - name: Program
          program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
          instructions:
            - name: Transfer
              account_filters:
                - position: 6
                  values: ["metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s"]
`,
      "must be in 0..=5",
    ),
    (
      "rejects duplicate positions inside one account-filter group",
      prefix ++ `
        - name: Program
          program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
          instructions:
            - name: Transfer
              account_filters:
                - position: 1
                  values: ["metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s"]
                - position: 1
                  values: ["metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s"]
`,
      "Duplicate position 1",
    ),
    (
      "rejects an empty any_of account filter",
      prefix ++ `
        - name: Program
          program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
          instructions:
            - name: Transfer
              account_filters:
                any_of: []
`,
      "`any_of` account filter",
    ),
    (
      "rejects an empty any_of group",
      prefix ++ `
        - name: Program
          program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
          instructions:
            - name: Transfer
              account_filters:
                any_of:
                  - []
`,
      "each `any_of` branch must contain at least one entry",
    ),
    (
      "rejects invalid account-filter pubkeys",
      prefix ++ `
        - name: Program
          program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
          instructions:
            - name: Transfer
              account_filters:
                - position: 1
                  values: ["not_a_pubkey"]
`,
      "invalid base58 pubkey",
    ),
  ]->Array.forEach(((name, yaml, message)) => {
    it(name, t => expectParseError(t, yaml, message))
  })

  it("rejects duplicate program names across chains", t => {
    expectParseError(
      t,
      `
name: duplicate-programs
ecosystem: svm
chains:
  - start_block: 0
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: Shared
          program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
          instructions: []
  - start_block: 0
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: shared
          program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
          instructions: []
`,
      "Duplicate program names detected",
    )
  })

  it("rejects chains without an RPC or HyperSync source", t => {
    expectParseError(
      t,
      `
name: missing-svm-source
ecosystem: svm
chains:
  - start_block: 0
`,
      "A chain must define a data source",
    )
  })
})

describe("schema validation errors through config YAML", () => {
  let baseYaml = `
name: schema-validation
chains:
  - id: 1
    start_block: 0
`

  [
    (
      "rejects entities without an id field",
      `
type Token {
  value: BigInt!
}
`,
      "No 'id' field found on entity Token",
    ),
    (
      "rejects duplicate fields",
      `
type Token {
  id: ID!
  value: BigInt!
  value: String!
}
`,
      "Found fields with duplicate names on Entity Token: 'value'",
    ),
    (
      "rejects an index that references a missing field",
      `
type Token @index(fields: ["missing"]) {
  id: ID!
}
`,
      "Field 'missing' does not exist in entity",
    ),
    (
      "rejects unknown storage directive arguments",
      `
type Token @storage(redis: true) {
  id: ID!
}
`,
      "Unknown argument `redis`",
    ),
    (
      "rejects entities routed to a disabled backend",
      `
type Token @storage(postgres: true, clickhouse: true) {
  id: ID!
}
`,
      "uses `clickhouse`, but `clickhouse` is not enabled",
    ),
    (
      "rejects fields that use derivedFrom and index together",
      `
type Token {
  id: ID!
  owner: String @derivedFrom(field: "tokens") @index
}
`,
      "A field cannot be both @derivedFrom and @index",
    ),
    (
      "rejects id fields with an index directive",
      `
type Token {
  id: ID! @index
}
`,
      "The field 'id' or 'ID' cannot be indexed or derivedFrom",
    ),
    (
      "rejects duplicate derivedFrom directives",
      `
type Token {
  id: ID!
  owner: String @derivedFrom(field: "one") @derivedFrom(field: "two")
}
`,
      "Cannot use more than one of the same directive on field owner",
    ),
    (
      "rejects duplicate field index directives",
      `
type Token {
  id: ID!
  value: String @index @index
}
`,
      "Cannot use more than one of the same directive on field value",
    ),
    (
      "rejects duplicate entity index definitions",
      `
type Token @index(fields: ["value"]) @index(fields: ["value"]) {
  id: ID!
  value: String!
}
`,
      "Duplicate index found on fields",
    ),
    (
      "rejects indexing a field both directly and from the entity",
      `
type Token @index(fields: ["value"]) {
  id: ID!
  value: String! @index
}
`,
      "The field 'value' is marked as an index",
    ),
    (
      "rejects indexing a derived field from the entity",
      `
type User @index(fields: ["tokens"]) {
  id: ID!
  tokens: [Token!]! @derivedFrom(field: "owner")
}
type Token {
  id: ID!
  owner: User!
}
`,
      "Field 'tokens' is a @derivedFrom field and cannot be indexed",
    ),
    (
      "rejects invalid index directions",
      `
type Token @index(fields: [["value", "SIDEWAYS"]]) {
  id: ID!
  value: String!
}
`,
      `Index direction must be "ASC" or "DESC"`,
    ),
    (
      "rejects malformed directional index entries",
      `
type Token @index(fields: [["value", "DESC", "extra"]]) {
  id: ID!
  value: String!
}
`,
      "must be a list of exactly 2 elements",
    ),
    (
      "rejects config directives on unsupported scalar types",
      `
type Token {
  id: ID!
  value: String @config(precision: 76)
}
`,
      "The config directive is only applicable to BigInt and BigDecimal",
    ),
    (
      "rejects unknown BigInt config arguments",
      `
type Token {
  id: ID!
  value: BigInt @config(scale: 2)
}
`,
      "The config directive on a BigInt should only have a 'precision' parameter",
    ),
    (
      "rejects unknown BigDecimal config arguments",
      `
type Token {
  id: ID!
  value: BigDecimal @config(precision: 20, scale: 2, rounding: 1)
}
`,
      "Unknown parameter(s) 'rounding'",
    ),
    (
      "requires both BigDecimal config arguments",
      `
type Token {
  id: ID!
  value: BigDecimal @config(precision: 20)
}
`,
      "must have both 'precision' and 'scale' parameters",
    ),
    (
      "rejects non-boolean storage arguments",
      `
type Token @storage(postgres: "yes") {
  id: ID!
}
`,
      "Argument `postgres` must be a boolean",
    ),
    (
      "rejects duplicate storage directives",
      `
type Token @storage(postgres: true) @storage(clickhouse: true) {
  id: ID!
}
`,
      "Only one @storage directive is allowed per entity",
    ),
    (
      "rejects duplicate storage arguments",
      `
type Token @storage(postgres: true, postgres: false) {
  id: ID!
}
`,
      "Argument `postgres` is specified more than once",
    ),
    (
      "rejects storage directives that disable every backend",
      `
type Token @storage(postgres: false, clickhouse: false) {
  id: ID!
}
`,
      "enables no storage",
    ),
    (
      "rejects empty storage directives",
      `
type Token @storage {
  id: ID!
}
`,
      "enables no storage",
    ),
  ]->Array.forEach(((name, schema, message)) => {
    it(name, t => expectParseError(t, ~schema, baseYaml, message))
  })

  it("rejects entities without a storage route when multiple backends have no default", t => {
    expectParseError(
      t,
      ~schema=`
type Zebra { id: ID! }
type Apple { id: ID! }
type Mango { id: ID! }
`,
      `
name: missing-storage-route
storage:
  postgres: true
  clickhouse: true
chains:
  - id: 1
    start_block: 0
`,
      "- Apple\n  - Mango\n  - Zebra",
    )
  })

  it("rejects snake_case column collisions", t => {
    expectParseError(
      t,
      ~schema=`
type Token {
  id: ID!
  tokenId: BigInt!
  token_id: BigInt!
}
`,
      `
name: column-collision
storage:
  postgres:
    column_name_format: snake_case
chains:
  - id: 1
    start_block: 0
`,
      `fields \`tokenId\`, \`token_id\` all map to the "token_id" column`,
    )
  })

  it("rejects nullable arrays on ClickHouse-backed entities", t => {
    expectParseError(
      t,
      ~schema=`
type Token @storage(postgres: true, clickhouse: true) {
  id: ID!
  tags: [String!]
}
`,
      `
name: nullable-clickhouse-array
storage:
  postgres: true
  clickhouse: true
chains:
  - id: 1
    start_block: 0
`,
      "Nullable array fields are not supported by ClickHouse storage",
    )
  })

  [
    (
      "rejects reference columns colliding under original naming",
      `
type Token { id: ID! }
type Transfer {
  id: ID!
  token: Token!
  token_id: BigInt!
}
`,
      `
name: reference-column-collision
chains:
  - id: 1
    start_block: 0
`,
      `fields \`token\`, \`token_id\` all map to the "token_id" column`,
    ),
    (
      "rejects reference columns colliding under snake_case naming",
      `
type Token { id: ID! }
type Transfer {
  id: ID!
  token: Token!
  tokenId: BigInt!
}
`,
      `
name: snake-reference-column-collision
storage:
  postgres:
    column_name_format: snake_case
chains:
  - id: 1
    start_block: 0
`,
      `fields \`token\`, \`tokenId\` all map to the "token_id" column`,
    ),
    (
      "rejects columns using the reserved envio prefix after snake_case conversion",
      `
type Token {
  id: ID!
  envioChange: BigInt!
}
`,
      `
name: reserved-column
storage:
  postgres:
    column_name_format: snake_case
chains:
  - id: 1
    start_block: 0
`,
      "Token.envioChange",
    ),
    (
      "rejects columns using the reserved envio prefix with original naming",
      `
type Token {
  id: ID!
  envio_checkpoint_id: BigInt!
}
`,
      `
name: reserved-column
chains:
  - id: 1
    start_block: 0
`,
      "Token.envio_checkpoint_id",
    ),
    (
      "rejects Postgres column names longer than 63 characters",
      `
type Token {
  id: ID!
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: BigInt!
}
`,
      `
name: long-column
chains:
  - id: 1
    start_block: 0
`,
      "database column names longer than 63 characters",
    ),
    (
      "applies collision checks when only ClickHouse uses snake_case",
      `
type Token {
  id: ID!
  tokenId: BigInt!
  token_id: BigInt!
}
`,
      `
name: clickhouse-column-collision
storage:
  postgres:
    default: true
    column_name_format: original
  clickhouse:
    default: true
    column_name_format: snake_case
chains:
  - id: 1
    start_block: 0
`,
      `fields \`tokenId\`, \`token_id\` all map to the "token_id" column`,
    ),
  ]->Array.forEach(((name, schema, yaml, message)) => {
    it(name, t => expectParseError(t, ~schema, yaml, message))
  })
})

describe("virtual ABI and IDL errors", () => {
  let evmYaml = `
name: abi-errors
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        abi_file_path: abis/Token.json
        events:
          - event: Transfer
`

  it("reports an ABI path omitted from virtual files", t => {
    expectParseError(t, evmYaml, `Virtual config file "abis/Token.json" was not provided`)
  })

  it("reports malformed ABI JSON", t => {
    expectParseError(
      t,
      ~files=Dict.fromArray([("abis/Token.json", "not json")]),
      evmYaml,
      "Failed to decode ABI file",
    )
  })

  it("reports events missing from an ABI", t => {
    expectParseError(
      t,
      ~files=Dict.fromArray([
        (
          "abis/Token.json",
          `[{"type":"event","name":"Approval","inputs":[],"anonymous":false}]`,
        ),
      ]),
      evmYaml,
      "Event Transfer not found in ABI file",
    )
  })

  it("reports an SVM IDL path omitted from virtual files", t => {
    expectParseError(
      t,
      `
name: missing-idl
ecosystem: svm
chains:
  - start_block: 0
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: Program
          program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
          idl: idls/program.json
          instructions: []
`,
      `Virtual config file "idls/program.json" was not provided`,
    )
  })

  it("rejects SVM IDL plus inline instruction layouts", t => {
    expectParseError(
      t,
      ~files=Dict.fromArray([("idls/program.json", "{}")]),
      `
name: duplicate-svm-schema
ecosystem: svm
chains:
  - start_block: 0
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: Program
          program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
          idl: idls/program.json
          instructions:
            - name: Transfer
              accounts: []
              args: []
`,
      "`idl` is mutually exclusive with per-instruction `accounts`/`args` overrides",
    )
  })

  it("requires SVM inline accounts and args together", t => {
    expectParseError(
      t,
      `
name: incomplete-svm-layout
ecosystem: svm
chains:
  - start_block: 0
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: Program
          program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
          instructions:
            - name: Transfer
              accounts: []
`,
      "`accounts` and `args` must be provided together",
    )
  })
})
