open Vitest

let schema = `
type Blob {
  id: ID!
  data: Bytes!
  optData: Bytes
  chunks: [Bytes!]!
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

let fuelFiles = Dict.fromArray([("abis/greeter-abi.json", FuelAbiFixtures.greeter)])
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
    start_block: 0
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
              accounts:
                - source
`

let expectBytesTyped = bytesType =>
  `
import type { Blob } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

expectType<
  TypeEqual<
    Blob,
    {
      readonly id: string;
      readonly data: ${bytesType};
      readonly optData: ${bytesType} | undefined;
      readonly chunks: readonly ${bytesType}[];
    }
  >
>(true);
`

let check = (~files=?, ~configYaml, ~bytesType) =>
  InternalTestIndexer.fromUserApi(
    ~schema,
    ~files?,
    ~handlers=expectBytesTyped(bytesType),
    ~configYaml,
  )->ignore

describe("bytes_type", () => {
  it("evm keeps Bytes as a hex string by default", _ =>
    check(~configYaml=`name: bytes-hex${evmChains}`, ~bytesType="string")
  )

  it("evm types Bytes as Uint8Array with bytes_type: uint8array", _ =>
    check(
      ~configYaml=`name: bytes-uint8array\nbytes_type: uint8array${evmChains}`,
      ~bytesType="Uint8Array",
    )
  )

  it("evm accepts bytes_type: hex explicitly", _ =>
    check(~configYaml=`name: bytes-hex-explicit\nbytes_type: hex${evmChains}`, ~bytesType="string")
  )

  it("fuel keeps Bytes as a hex string by default", _ =>
    check(~files=fuelFiles, ~configYaml=`name: fuel-bytes-hex${fuelChains}`, ~bytesType="string")
  )

  it("fuel types Bytes as Uint8Array with bytes_type: uint8array", _ =>
    check(
      ~files=fuelFiles,
      ~configYaml=`name: fuel-bytes-uint8array\nbytes_type: uint8array${fuelChains}`,
      ~bytesType="Uint8Array",
    )
  )

  it("svm always types Bytes as Uint8Array", _ =>
    check(~configYaml=`name: svm-bytes${svmChains}`, ~bytesType="Uint8Array")
  )

  it("svm has no bytes_type option", t =>
    t->toThrowErrorEqual(
      () =>
        check(~configYaml=`name: svm-bytes\nbytes_type: hex${svmChains}`, ~bytesType="Uint8Array"),
      "Failed to deserialize config. Visit the docs for more information https://docs.envio.dev/docs/configuration-file: unknown field `bytes_type`",
    )
  )

  it("evm rejects an unknown bytes_type", t =>
    t->toThrowErrorEqual(
      () => check(~configYaml=`name: bytes-bad\nbytes_type: raw${evmChains}`, ~bytesType="string"),
      "Failed to deserialize config. Visit the docs for more information https://docs.envio.dev/docs/configuration-file: bytes_type: unknown variant `raw`, expected `hex` or `uint8array` at line 2 column 13",
    )
  )
})
