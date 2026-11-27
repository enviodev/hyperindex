// https://github.com/enviodev/hyperindex/issues/1808
// Projects default to `skipLibCheck: true`, which hides an error in a `.d.ts`
// and turns whatever it touches into `any`. Every generated types file and
// envio's own declarations must check cleanly without it.
open Vitest

describe("generated and envio declarations", () => {
  it("type-check without skipLibCheck for every ecosystem", t =>
    t.expect([
      InternalTestIndexer.declarationErrors(
        ~schema=ApiTypesFixtures.schema,
        `
name: evm-declarations
field_selection:
  transaction_fields:
    - hash
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
      - event: Matrix(uint256[][] indexed rows, uint256[][] columns)
        field_selection:
          block_fields:
            - parentHash
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
`,
      ),
      InternalTestIndexer.declarationErrors(
        ~schema=ApiTypesFixtures.schema,
        ~files=dict{"abis/greeter-abi.json": FuelAbiFixtures.greeter},
        `
name: fuel-declarations
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
      ),
      InternalTestIndexer.declarationErrors(
        ~schema=ApiTypesFixtures.schema,
        `
name: svm-declarations
ecosystem: svm
chains:
  - id: solana
    start_slot: 0
programs:
  - name: Swapper
    program_id: 675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8
    instructions:
      - name: swap
        discriminator: "0x09"
        args:
          - name: amount
            type: u64
        accounts:
          - source
`,
      ),
    ]).toEqual([[], [], []])
  )
})
