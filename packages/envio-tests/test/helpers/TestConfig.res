// A parsed config for tests that need one but never index against it: chain
// state, indexer state, storage wiring. Whatever such a test asserts on comes
// from the test itself, so the default fixture stays at one chain and one
// contract.
//
// Parsed straight from the user API rather than through `Scenario`: these tests
// pick their own storage, so the scenario backend must not reshape the config
// under them.

let defaultSchema = `
type SimpleEntity {
  id: ID!
  value: String!
}
`

// Both halves of what a resume compares: the parsed config a run uses, and the
// snapshot the storage persists and diffs against.
type parsed = {config: Config.t, envioInfo: JSON.t}

let parse = (~schema=defaultSchema, configYaml) => {
  let publicConfigJson = Core.fromUserApi(~schema, configYaml).config->JSON.parseOrThrow
  {
    config: publicConfigJson->Config.fromPublic,
    envioInfo: publicConfigJson->Config.stripSensitiveData,
  }
}

let fromUserApi = (~schema=defaultSchema, configYaml) => parse(~schema, configYaml).config

// One chain per entry, each with the contract it names. Contract names are
// unique across chains, which the config parser requires of anything that isn't
// a global contract definition.
let multiChain = (~chains: array<(int, string)>, ~schema=defaultSchema, ~extra="") =>
  parse(
    ~schema,
    `
name: test-config${extra}
chains:
${chains
      ->Array.map(((chainId, contract)) =>
        `  - id: ${chainId->Int.toString}
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: ${contract}
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"`
      )
      ->Array.joinUnsafe("\n")}
`,
  )

let make = (~chainId=1, ~schema=defaultSchema) =>
  fromUserApi(
    ~schema,
    `
name: test-config
chains:
  - id: ${chainId->Int.toString}
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  )

let default = make()
