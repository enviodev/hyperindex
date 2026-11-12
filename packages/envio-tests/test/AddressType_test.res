open Vitest

let schema = `
type Token {
  id: Address!
  owner: Address!
  optOwner: Address
  owners: [Address!]!
  holders: [Holder!]! @derivedFrom(field: "token")
}
type Holder {
  id: ID!
  token: Token!
}
`

let evmChains = `
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`

let fuelFiles = dict{"abis/greeter-abi.json": FuelAbiFixtures.greeter}
let fuelChains = `
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
`

let svmChains = `
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
          - { name: amountIn, type: u64 }
        accounts:
          - source
`

let expectAddressTyped = addressType =>
  `
import type { ${addressType === "Address" ? "Address, " : ""}Holder, Token } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

expectType<
  TypeEqual<
    Token,
    {
      readonly id: ${addressType};
      readonly owner: ${addressType};
      readonly optOwner: ${addressType} | undefined;
      readonly owners: readonly ${addressType}[];
    }
  >
>(true);

expectType<TypeEqual<Holder, { readonly id: string; readonly token_id: ${addressType} }>>(true);
`

let check = (~files=?, ~configYaml, ~addressType) =>
  InternalTestIndexer.fromUserApi(
    ~schema,
    ~files?,
    ~handlers=expectAddressTyped(addressType),
    ~configYaml,
  )->ignore

describe("Address entity fields", () => {
  it("evm types an Address field as Address", _ =>
    check(~configYaml=`name: address-evm${evmChains}`, ~addressType="Address")
  )

  it("evm types an Address field as Address under address_format: lowercase", _ =>
    check(
      ~configYaml=`name: address-evm-lowercase\naddress_format: lowercase${evmChains}`,
      ~addressType="Address",
    )
  )

  it("fuel types an Address field as Address", _ =>
    check(~files=fuelFiles, ~configYaml=`name: address-fuel${fuelChains}`, ~addressType="Address")
  )

  it("svm types an Address field as a base58 string", _ =>
    check(~configYaml=`name: address-svm${svmChains}`, ~addressType="string")
  )

  // Schemas could define a type named Address before it was a scalar.
  it("keeps a schema's own Address entity as the type it names", _ =>
    InternalTestIndexer.fromUserApi(
      ~schema=`
type Address {
  id: ID!
  tokens: [Token!]! @derivedFrom(field: "owner")
}
type Token {
  id: ID!
  owner: Address!
}
`,
      ~handlers=`
import type { Token } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

expectType<TypeEqual<Token, { readonly id: string; readonly owner_id: string }>>(true);
`,
      ~configYaml=`name: address-entity${evmChains}`,
    )->ignore
  )
})
