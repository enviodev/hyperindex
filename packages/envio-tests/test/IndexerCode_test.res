open Vitest

// Snapshots of the generated `src/Indexer.res` for the ecosystems no in-repo
// project covers. The snapshots live under `test/generated/`, which is part of
// this package's ReScript sources — so `pnpm rescript` type-checks the codegen
// output as well as diffing it. Update with `pnpm vitest run -u`.
let snapshot = (t, ~configYaml, ~schema, ~files=?, ~path) => {
  let {indexerCode} = InternalTestIndexer.fromUserApi(
    ~schema,
    ~files?,
    ~withIndexerCode=true,
    ~configYaml,
  )
  t.expect(indexerCode->Option.getOrThrow).toMatchFileSnapshot(path)
}

let schema = `
type Account {
  id: ID!
  balance: BigInt!
}
`

describe("Generated Indexer.res", () => {
  Async.it("matches the snapshot for Fuel", async t =>
    await t->snapshot(
      ~files=Dict.fromArray([("abis/greeter-abi.json", FuelAbiFixtures.greeter)]),
      ~configYaml=`
name: fuel-indexer-code
ecosystem: fuel
chains:
  - id: 0
    start_block: 0
    contracts:
      - name: Greeter
        address: 0xb9bc445e5696c966dcf7e5d1237bd03c04e3ba6929bdaedfeebc7aae784c3a0b
        abi_file_path: abis/greeter-abi.json
        events:
          - name: NewGreeting
          - name: ClearGreeting
`,
      ~schema,
      ~path="./generated/FuelIndexer.res",
    )
  )

  Async.it("matches the snapshot for SVM", async t =>
    await t->snapshot(
      ~configYaml=`
name: svm-indexer-code
ecosystem: svm
chains:
  - start_block: 0
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: Swapper
          program_id: 675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8
          instructions:
            - name: swap
              discriminator: "0x09"
              args:
                - { name: amountIn, type: u64 }
                - { name: minAmountOut, type: u64 }
              accounts:
                - source
                - destination
`,
      ~schema,
      ~path="./generated/SvmIndexer.res",
    )
  )
})
