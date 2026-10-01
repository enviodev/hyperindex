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

let fromUserApi = (~schema=defaultSchema, configYaml) =>
  Core.fromUserApi(~schema, configYaml).config->JSON.parseOrThrow->Config.fromPublic

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
