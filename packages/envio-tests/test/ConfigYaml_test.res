open Vitest

let expectParseError = (t, ~schema=?, ~env=?, ~files=?, yaml, message) => {
  let actual = try {
    MockIndexerConfig.parseYaml(~schema?, ~env?, ~files?, yaml)->ignore
    "the parse to fail, but it succeeded"
  } catch {
  | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
  }
  t.expect(actual).toBe(message)
}

let parseAddressConfig = (~addressFormat="checksum", ~contractName="ERC20", address): Config.t =>
  MockIndexerConfig.parseYaml(`
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

describe("MockIndexerConfig.parseYaml", () => {
  it("parses user YAML with explicit env and no project schema", t => {
    let env = Dict.fromArray([
      ("RPC_URL", "https://rpc.example.test"),
      ("START_BLOCK", "42"),
    ])

    let {config} = MockIndexerConfig.parseYaml(
      ~env,
      `
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

    let {config} = MockIndexerConfig.parseYaml(
      ~files,
      `
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
      "Config parse error: Address 0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9 on chain 1 is configured for multiple contracts: AaveToken and AaveV3. Indexing the same address with multiple contract definitions is not supported. Please define the events on a single contract definition instead.",
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
      "Config parse error: Address 0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9 is listed multiple times for the contract AaveToken on chain 1. Please remove the duplicate from your config.",
    )
  })

  it("allows the same address on different chains", t => {
    let {config} = MockIndexerConfig.parseYaml(`
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
    let {config} = MockIndexerConfig.parseYaml(
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
      `
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
    let {config} = MockIndexerConfig.parseYaml(
      ~schema=`
type User { id: ID! }
type Snapshot @storage(clickhouse: true) { id: ID! }
`,
      `
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
    let {config} = MockIndexerConfig.parseYaml(
      ~schema=`
type User {
  id: ID!
  userId: BigInt!
}
`,
      `
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
      "Config parse error: Failed to interpolate variables into your config file. Environment variables are not present: MISSING_RPC_URL",
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
      "Config parse error: Failed to interpolate variables into your config file. Invalid environment variables are present: \"My RPC URL\"",
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
      "Config parse error: Failed to interpolate variables into your config file. Unbalanced '${' expression: ${MISSING:-${FALLBACK}\n      for: sync\n    start_block: 0\n",
    )
  })
})

describe("human config YAML errors", () => {
  [
    (
      "rejects malformed YAML",
      "name: [unterminated\n",
      "Config parse error: Failed to deserialize config. The config.yaml file is either not a valid yaml or the \"ecosystem\" field is not a string.: did not find expected ',' or ']' at line 2 column 1, while parsing a flow sequence at line 1 column 7",
    ),
    (
      "rejects a non-string ecosystem",
      `
name: wrong-ecosystem-type
ecosystem: {}
chains: []
`,
      "Config parse error: Failed to deserialize config. The config.yaml file is either not a valid yaml or the \"ecosystem\" field is not a string.: ecosystem: invalid type: map, expected a string at line 3 column 12",
    ),
    (
      "rejects an unsupported ecosystem",
      `
name: unsupported
ecosystem: cosmos
chains: []
`,
      "Config parse error: Failed to deserialize config. The ecosystem \"cosmos\" is not supported.",
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
      "Config parse error: Failed to deserialize config. Visit the docs for more information https://docs.envio.dev/docs/configuration-file: unknown field \`bigquery\`, expected \`postgres\` or \`clickhouse\` at line 2 column 1",
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
      "Config parse error: Failed to deserialize config. Visit the docs for more information https://docs.envio.dev/docs/configuration-file: unknown field \`defautl\`, expected \`default\` or \`column_name_format\` at line 2 column 1",
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
      "Config parse error: Failed to deserialize config. Visit the docs for more information https://docs.envio.dev/docs/configuration-file: unknown variant \`kebab-case\`, expected \`original\` or \`snake_case\` at line 2 column 1",
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
      "Config parse error: Failed to deserialize config. Visit the docs for more information https://docs.envio.dev/docs/configuration-file: invalid type: string \"enabled\", expected a boolean or an options object like \`{default: true}\` at line 2 column 1",
    ),
    (
      "rejects numeric separators instead of silently treating them as numbers",
      `
name: numeric-separator
chains:
  - id: 1
    start_block: 1_000
`,
      "Config parse error: Failed to deserialize config. Visit the docs for more information https://docs.envio.dev/docs/configuration-file: chains[0].start_block: invalid type: string \"1_000\", expected u64 at line 5 column 18",
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
      "Config parse error: Failed to deserialize config. Visit the docs for more information https://docs.envio.dev/docs/configuration-file: chains[0].experimental.programs[0]: unknown field \`bogus_extra\`, expected one of \`name\`, \`program_id\`, \`handler\`, \`idl\`, \`instructions\` at line 12 column 11",
    ),
  ]->Array.forEach(((name, yaml, message)) => {
    it(name, t => expectParseError(t, yaml, message))
  })
})

describe("system config validation errors", () => {
  it("rejects two events on one contract that the indexer can't tell apart", t => {
    expectParseError(
      t,
      `
name: duplicate-event
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    start_block: 0
`,
      "Config parse error: Failed parsing globally defined contract: Contract Token has two events the indexer can't tell apart: Transfer and Transfer. Please remove one of them.",
    )
  })

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
      "Config parse error: Failed parsing abi types for events in global contract Token: No abi file provided for event Transfer",
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
      "Config parse error: Failed parsing abi types for events in global contract Token: Failed to parse ABI type 'uint69' for event parameter 'value': Failed to parse leaf ABI type 'uint69': invalid size for type: uint69: invalid size for type: uint69",
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
      "Config parse error: ClickHouse is not supported as a single storage yet. Please enable Postgres alongside ClickHouse in the \`storage\` config.",
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
      "Config parse error: At least one storage backend must be enabled. Please set \`postgres: true\` in the \`storage\` config (or omit the \`storage\` section entirely to use the default).",
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
      "Config parse error: The config has an end_block smaller than start_block for chain 1. end_block must be greater than or equal to start_block.",
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
      "Config parse error: Cannot define both hypersync_config and rpc as a data-source for historical sync at the same time, please choose only one option or set RPC to be a fallback. Read more in our docs https://docs.envio.dev/docs/configuration-file",
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
      "Config parse error: The RPC url \"ftp://rpc.example.test\" is incorrect format. The RPC url needs to start with either http:// or https://",
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
      "Config parse error: The WebSocket URL \"https://rpc.example.test/ws\" is in incorrect format. Expected wss:// or ws:// protocol.",
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
      "Config parse error: The HyperSync URL \"ftp://hypersync.example.test\" is in incorrect format. The URL needs to start with either http:// or https://",
    ),
    (
      "rejects unknown chains without an explicit sync source",
      `
name: missing-evm-source
chains:
  - id: 999999
    start_block: 0
`,
      "Config parse error: Failed to automatically find HyperSync endpoint for the chain 999999. If the chain is supported by HyperSync, provide the endpoint manually:\n\nchains:\n  - id: 999999\n    hypersync_config:\n      url: https://999999.hypersync.xyz\n\nOr use an RPC endpoint for historical sync:\n\nchains:\n  - id: 999999\n    rpc:\n      url: https://your-rpc-endpoint\n      for: sync\n\nRead more: https://docs.envio.dev/docs/HyperIndex/config-schema-reference#hypersyncconfig",
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
      "Config parse error: transaction_fields selection contains the following duplicates: hash",
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
      "Config parse error: block_fields selection contains the following duplicates: parentHash",
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
      "Config parse error: The following selected transaction_fields are unavailable for indexing via RPC: gas",
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
      "Config parse error: The following selected block_fields are unavailable for indexing via RPC: sha3Uncles",
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
      "Config parse error: Failed parsing abi types for events in contract Token on network 999999: The following selected transaction_fields are unavailable for indexing via RPC: gas",
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
      "Config parse error: Failed parsing abi types for events in global contract Token: The following selected transaction_fields are unavailable for indexing via RPC: gas",
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
      "Config parse error: Duplicate contract names detected. All contract names must be unique across all networks, and are case-insensitive. For multichain indexing, consider using a global contract definition. More information is available at: https://docs.envio.dev/docs/HyperIndex/multichain-indexing",
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
      "Config parse error: Failed to parse contract 'Missing' for the network '1'. If you use a global contract definition, please verify that the name reference is correct.",
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
      "Config parse error: Failed inserting chain at chains map: 1 already exists, cannot have duplicates",
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
      "Config parse error: Fuel network id 42 is not supported",
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
      "Config parse error: The config contains invalid characters for contract names: \"Has-Hyphen\". They are used for the generated code and must be valid identifiers, containing only alphanumeric characters and underscores.",
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
      "Config parse error: The config contains reserved words for contract names: \"module\". They are used for the generated code and must be valid identifiers, containing only alphanumeric characters and underscores.",
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
      "Failed serializing config: All chains are skipped. At least one chain must be active to run the indexer.",
    ),
  ]->Array.forEach(((name, yaml, message)) => {
    it(name, t => expectParseError(t, yaml, message))
  })
})

describe("config YAML success cases", () => {
  it("allows distinct events on one contract and the same event across contracts", t => {
    // Distinct signatures on one contract are fine, and the same event on two
    // different contracts is allowed — routing scopes matches by contract.
    let {config} = MockIndexerConfig.parseYaml(`
name: distinct-and-cross-contract-events
contracts:
  - name: ERC20
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
      - event: Approval(address indexed owner, address indexed spender, uint256 value)
  - name: ERC721
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    rpc:
      url: https://eth.com
      for: sync
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1111111111111111111111111111111111111111"
      - name: ERC721
        address: "0x2222222222222222222222222222222222222222"
`)
    let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
    t.expect(chain.contracts->Array.length).toBe(2)
  })

  it("parses a minimal Fuel config through the public boundary", t => {
    let {config} = MockIndexerConfig.parseYaml(`
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
    let {config} = MockIndexerConfig.parseYaml(`
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
    let {config} = MockIndexerConfig.parseYaml(`
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
    let {config} = MockIndexerConfig.parseYaml(`
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
    let {config} = MockIndexerConfig.parseYaml(`
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
    let {config} = MockIndexerConfig.parseYaml(`
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
    let {config} = MockIndexerConfig.parseYaml(
      ~files,
      `
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
    let {config} = MockIndexerConfig.parseYaml(`
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
    let {config} = MockIndexerConfig.parseYaml(
      ~schema=`type Token { id: ID! }`,
      `
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
      "Config parse error: Program \"Program\" has an invalid program_id \"not_a_pubkey\": must be a base58-encoded 32-byte Solana pubkey",
    ),
    (
      "rejects base58 program ids that do not decode to 32 bytes",
      prefix ++ `
        - name: Program
          program_id: 111111111111111111111111111111111
          instructions: []
`,
      "Config parse error: Program \"Program\" has an invalid program_id \"111111111111111111111111111111111\": must be a base58-encoded 32-byte Solana pubkey",
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
      "Config parse error: Program \"Program\" declares the instruction \"Transfer\" more than once",
    ),
    (
      "rejects two instructions whose discriminators differ only in hex casing",
      prefix ++ `
        - name: Program
          program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
          instructions:
            - {name: Transfer, discriminator: "0x0f"}
            - {name: Withdraw, discriminator: "0x0F"}
`,
      "Config parse error: Contract Program has two events the indexer can't tell apart: Transfer and Withdraw. Please remove one of them.",
    ),
    (
      "rejects invalid discriminators",
      prefix ++ `
        - name: Program
          program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
          instructions:
            - {name: Transfer, discriminator: "0x012"}
`,
      "Config parse error: instruction \"Transfer\" in program \"Program\": discriminator \"0x012\" must be 1, 2, 4, or 8 bytes (i.e. 2, 4, 8, or 16 hex digits after stripping a \`0x\` prefix), got 3 digits",
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
      "Config parse error: Account filter position 6 in instruction \"Transfer\" (program \"Program\") must be in 0..=5 (positions 6..=9 are reserved for a future extension)",
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
      "Config parse error: Duplicate position 1 in account filter group 0 of instruction \"Transfer\" (program \"Program\"); combine the pubkeys into a single \`values\` list, or use \`any_of\` to express OR across positions",
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
      "Config parse error: \`any_of\` account filter on instruction \"Transfer\" (program \"Program\") is empty; remove the \`account_filters\` field instead, or add at least one AND-group",
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
      "Config parse error: Account filter group 0 in instruction \"Transfer\" (program \"Program\") is empty; each \`any_of\` branch must contain at least one entry",
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
      "Config parse error: Account filter on instruction \"Transfer\" (program \"Program\") has an invalid base58 pubkey \"not_a_pubkey\"",
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
      "Config parse error: Duplicate program names detected. All program names must be unique across all chains and are case-insensitive.",
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
      "Config parse error: A chain must define a data source: either an \`rpc\` endpoint or an \`experimental\` HyperSync config. Both are missing.",
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
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: No 'id' field found on entity Token. Please add an 'id' field to your entity.",
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
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Failed constructing entity Token: Found fields with duplicate names on Entity Token: 'value'",
    ),
    (
      "rejects an index that references a missing field",
      `
type Token @index(fields: ["missing"]) {
  id: ID!
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Failed constructing entity Token: Invalid multi field indexes on Entity Token: Index error: Field 'missing' does not exist in entity, please remove it from the \`@index\` directive.",
    ),
    (
      "rejects unknown storage directive arguments",
      `
type Token @storage(redis: true) {
  id: ID!
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Invalid @storage directive on \`Token\`. Unknown argument \`redis\`. Expected args from {postgres, clickhouse}: \`postgres\` takes a boolean, \`clickhouse\` takes a boolean or a table options object, e.g. @storage(postgres: true, clickhouse: true) or @storage(clickhouse: {partitionBy: \"toYYYYMM(timestamp)\", orderBy: [\"timestamp\"], ttl: \"timestamp + INTERVAL 2 YEAR\"}).",
    ),
    (
      "rejects entities routed to a disabled backend",
      `
type Token @storage(postgres: true, clickhouse: true) {
  id: ID!
}
`,
      "Config parse error: Schema validation failed:\n\nEntities using storages not enabled in config.yaml:\n  - \`Token\` uses \`clickhouse\`, but \`clickhouse\` is not enabled.\n\nFixes:\n  - Remove the unsupported storage from @storage on these entities, or enable it under \`storage:\` in config.yaml.",
    ),
    (
      "rejects fields that use derivedFrom and index together",
      `
type Token {
  id: ID!
  owner: String @derivedFrom(field: "tokens") @index
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Failed parsing fields on entity Token: A field cannot be both @derivedFrom and @index: owner",
    ),
    (
      "rejects id fields with an index directive",
      `
type Token {
  id: ID! @index
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Failed parsing fields on entity Token: The field 'id' or 'ID' cannot be indexed or derivedFrom. Please remove the @index or @derivedFrom directive from field id",
    ),
    (
      "rejects duplicate derivedFrom directives",
      `
type Token {
  id: ID!
  owner: String @derivedFrom(field: "one") @derivedFrom(field: "two")
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Failed parsing fields on entity Token: Cannot use more than one of the same directive on field owner",
    ),
    (
      "rejects duplicate field index directives",
      `
type Token {
  id: ID!
  value: String @index @index
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Failed parsing fields on entity Token: Cannot use more than one of the same directive on field value",
    ),
    (
      "rejects duplicate entity index definitions",
      `
type Token @index(fields: ["value"]) @index(fields: ["value"]) {
  id: ID!
  value: String!
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Failed constructing entity Token: Index error: Duplicate index found on fields [\"value\"] in entity 'Token'",
    ),
    (
      "rejects indexing a field both directly and from the entity",
      `
type Token @index(fields: ["value"]) {
  id: ID!
  value: String! @index
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Failed constructing entity Token: Invalid multi field indexes on Entity Token: The field 'value' is marked as an index. Please either remove the @index directive on the field, or the @index(fields: [\"value\"]) directive on the entity",
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
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Failed constructing entity User: Invalid multi field indexes on Entity User: Index error: Field 'tokens' is a @derivedFrom field and cannot be indexed, please remove it from the \`@index\` directive.",
    ),
    (
      "rejects invalid index directions",
      `
type Token @index(fields: [["value", "SIDEWAYS"]]) {
  id: ID!
  value: String!
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Failed parsing multi field indexes on entity Token: Failed to get fields in index: Index direction must be \"ASC\" or \"DESC\", got \"SIDEWAYS\"",
    ),
    (
      "rejects malformed directional index entries",
      `
type Token @index(fields: [["value", "DESC", "extra"]]) {
  id: ID!
  value: String!
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Failed parsing multi field indexes on entity Token: Failed to get fields in index: Index field with direction must be a list of exactly 2 elements: [\"fieldName\", \"ASC\" or \"DESC\"]. Got 3 elements.",
    ),
    (
      "rejects config directives on unsupported scalar types",
      `
type Token {
  id: ID!
  value: String @config(precision: 76)
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Failed parsing fields on entity Token: The config directive is only applicable to BigInt and BigDecimal scalar types. Field 'value'",
    ),
    (
      "rejects unknown BigInt config arguments",
      `
type Token {
  id: ID!
  value: BigInt @config(scale: 2)
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Failed parsing fields on entity Token: The config directive on a BigInt should only have a 'precision' parameter. Unknown parameter 'scale'. Field 'value'",
    ),
    (
      "rejects unknown BigDecimal config arguments",
      `
type Token {
  id: ID!
  value: BigDecimal @config(precision: 20, scale: 2, rounding: 1)
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Failed parsing fields on entity Token: The config directive on a BigDecimal should only have 'precision' and 'scale' parameters. Unknown parameter(s) 'rounding'. Field 'value'",
    ),
    (
      "requires both BigDecimal config arguments",
      `
type Token {
  id: ID!
  value: BigDecimal @config(precision: 20)
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Failed parsing fields on entity Token: The config directive on a BigDecimal must have both 'precision' and 'scale' parameters. Field 'value'",
    ),
    (
      "rejects non-boolean storage arguments",
      `
type Token @storage(postgres: "yes") {
  id: ID!
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Invalid @storage directive on \`Token\`. Argument \`postgres\` must be a boolean. Expected args from {postgres, clickhouse}: \`postgres\` takes a boolean, \`clickhouse\` takes a boolean or a table options object, e.g. @storage(postgres: true, clickhouse: true) or @storage(clickhouse: {partitionBy: \"toYYYYMM(timestamp)\", orderBy: [\"timestamp\"], ttl: \"timestamp + INTERVAL 2 YEAR\"}).",
    ),
    (
      "rejects duplicate storage directives",
      `
type Token @storage(postgres: true) @storage(clickhouse: true) {
  id: ID!
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Invalid @storage directive on \`Token\`. Only one @storage directive is allowed per entity. Expected args from {postgres, clickhouse}: \`postgres\` takes a boolean, \`clickhouse\` takes a boolean or a table options object, e.g. @storage(postgres: true, clickhouse: true) or @storage(clickhouse: {partitionBy: \"toYYYYMM(timestamp)\", orderBy: [\"timestamp\"], ttl: \"timestamp + INTERVAL 2 YEAR\"}).",
    ),
    (
      "rejects duplicate storage arguments",
      `
type Token @storage(postgres: true, postgres: false) {
  id: ID!
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Invalid @storage directive on \`Token\`. Argument \`postgres\` is specified more than once. Expected args from {postgres, clickhouse}: \`postgres\` takes a boolean, \`clickhouse\` takes a boolean or a table options object, e.g. @storage(postgres: true, clickhouse: true) or @storage(clickhouse: {partitionBy: \"toYYYYMM(timestamp)\", orderBy: [\"timestamp\"], ttl: \"timestamp + INTERVAL 2 YEAR\"}).",
    ),
    (
      "rejects storage directives that disable every backend",
      `
type Token @storage(postgres: false, clickhouse: false) {
  id: ID!
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: @storage on \`Token\` enables no storage. At least one of {postgres, clickhouse} must be true.",
    ),
    (
      "rejects unknown clickhouse table options",
      `
type Token @storage(clickhouse: {indexGranularity: 1024}) {
  id: ID!
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Invalid @storage directive on \`Token\`. Unknown \`clickhouse\` option \`indexGranularity\`. Expected options from {partitionBy, orderBy, ttl}, e.g. clickhouse: {partitionBy: \"toYYYYMM(timestamp)\", orderBy: [\"timestamp\"], ttl: \"timestamp + INTERVAL 2 YEAR\"}.",
    ),
    (
      "rejects clickhouse orderBy referencing missing fields",
      `
type Token @storage(clickhouse: {orderBy: ["missing"]}) {
  id: ID!
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Failed constructing entity Token: Invalid @storage directive on \`Token\`. \`clickhouse.orderBy\` references field \`missing\` which doesn't exist on the entity. Use the field names as written in the schema.",
    ),
    (
      "rejects clickhouse orderBy listing id",
      `
type Token @storage(clickhouse: {orderBy: ["id"]}) {
  id: ID!
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Failed constructing entity Token: Invalid @storage directive on \`Token\`. \`clickhouse.orderBy\` must not list \`id\`: it's already the default sorting key. List only the additional fields to sort by.",
    ),
    (
      "rejects clickhouse orderBy on BigInt fields",
      `
type Token @storage(clickhouse: {orderBy: ["amount"]}) {
  id: ID!
  amount: BigInt!
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: Failed constructing entity Token: Invalid @storage directive on \`Token\`. \`clickhouse.orderBy\` field \`amount\` is a BigInt/BigDecimal, which ClickHouse can store as a String (lexicographic, not numeric ordering). Sorting by it isn't supported yet.",
    ),
    (
      "rejects empty storage directives",
      `
type Token @storage {
  id: ID!
}
`,
      "Config parse error: Failed converting schema doc to schema struct: Failed constructing entities in schema from document: @storage on \`Token\` enables no storage. At least one of {postgres, clickhouse} must be true.",
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
      "Config parse error: Schema validation failed:\n\nEntities with no storage backend (no @storage directive, and no backend is marked \`default: true\` in config.yaml):\n  - Apple\n  - Mango\n  - Zebra\n\nFixes:\n  - Set \`default: true\` on a backend under \`storage:\` in config.yaml to include these entities automatically. Example:\n      storage:\n        postgres:\n          default: true\n  - Or add @storage(postgres: true) and/or @storage(clickhouse: true) to the entities listed above. Example:\n      type Apple @storage(postgres: true) { ... }",
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
      "Config parse error: Schema validation failed:\n\nMultiple entity fields map to the same database column:\n  - \`Token\`: fields \`tokenId\`, \`token_id\` all map to the \"token_id\" column.\n\nFixes:\n  - Rename the conflicting fields in schema.graphql so they map to distinct columns. Note that entity reference fields get an \`_id\` suffix, and \`column_name_format: snake_case\` converts field names to snake_case.",
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
      "Config parse error: Schema validation failed:\n\nNullable array fields are not supported by ClickHouse storage:\n  - \`Token.tags\` has type \`[String!]\`\n\nFixes:\n  - Make the field required and explicitly set an empty array instead of null. For example, change the type from \`[String!]\` to \`[String!]!\` in schema.graphql, and assign \`[]\` instead of \`null\`/\`undefined\` in your handlers.",
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
      "Config parse error: Schema validation failed:\n\nMultiple entity fields map to the same database column:\n  - \`Transfer\`: fields \`token\`, \`token_id\` all map to the \"token_id\" column.\n\nFixes:\n  - Rename the conflicting fields in schema.graphql so they map to distinct columns. Note that entity reference fields get an \`_id\` suffix, and \`column_name_format: snake_case\` converts field names to snake_case.",
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
      "Config parse error: Schema validation failed:\n\nMultiple entity fields map to the same database column:\n  - \`Transfer\`: fields \`token\`, \`tokenId\` all map to the \"token_id\" column.\n\nFixes:\n  - Rename the conflicting fields in schema.graphql so they map to distinct columns. Note that entity reference fields get an \`_id\` suffix, and \`column_name_format: snake_case\` converts field names to snake_case.",
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
      "Config parse error: Schema validation failed:\n\nEntity fields that would create database columns with the reserved \`envio_\` prefix:\n  - \`Token.envioChange\` maps to the \"envio_change\" column.\n\nFixes:\n  - Rename the listed fields in schema.graphql. Column names starting with \`envio_\` are reserved for internal indexer columns (eg \`envio_change\` in entity history tables).",
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
      "Config parse error: Schema validation failed:\n\nEntity fields that would create database columns with the reserved \`envio_\` prefix:\n  - \`Token.envio_checkpoint_id\` maps to the \"envio_checkpoint_id\" column.\n\nFixes:\n  - Rename the listed fields in schema.graphql. Column names starting with \`envio_\` are reserved for internal indexer columns (eg \`envio_change\` in entity history tables).",
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
      "Config parse error: Schema validation failed:\n\nEntity fields that would create database column names longer than 63 characters (Postgres truncates longer identifiers, which can cause collisions and broken GraphQL field mappings):\n  - \`Token.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\` maps to the \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\" column (64 characters).\n\nFixes:\n  - Shorten the listed fields in schema.graphql so the resulting column names fit within 63 characters.",
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
      "Config parse error: Schema validation failed:\n\nMultiple entity fields map to the same database column:\n  - \`Token\`: fields \`tokenId\`, \`token_id\` all map to the \"token_id\" column.\n\nFixes:\n  - Rename the conflicting fields in schema.graphql so they map to distinct columns. Note that entity reference fields get an \`_id\` suffix, and \`column_name_format: snake_case\` converts field names to snake_case.",
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
    expectParseError(t, evmYaml, "Config parse error: Failed parsing abi types for events in contract Token on network 1: Failed to get ABI relative to the config: Virtual config file \"abis/Token.json\" was not provided")
  })

  it("reports malformed ABI JSON", t => {
    expectParseError(
      t,
      ~files=Dict.fromArray([("abis/Token.json", "not json")]),
      evmYaml,
      "Config parse error: Failed parsing abi types for events in contract Token on network 1: Failed to decode ABI file at \"abis/Token.json\": expected ident at line 1 column 2",
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
      "Config parse error: Failed parsing abi types for events in contract Token on network 1: Event Transfer not found in ABI file",
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
      "Config parse error: Resolving Borsh schema for program 'Program' (metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s): reading IDL at 'idls/program.json': Virtual config file \"idls/program.json\" was not provided",
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
      "Config parse error: Resolving Borsh schema for program 'Program' (metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s): Program 'Program': \`idl\` is mutually exclusive with per-instruction \`accounts\`/\`args\` overrides. Use one or the other.",
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
      "Config parse error: Layout for instruction 'Transfer': Instruction 'Transfer': \`accounts\` and \`args\` must be provided together (or both omitted to fall back to a bundled/IDL schema).",
    )
  })
})
