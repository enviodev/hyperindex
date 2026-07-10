type hex = EvmTypes.Hex.t
@module("viem") external toHex: 'a => hex = "toHex"
@module("viem") external keccak256: hex => hex = "keccak256"
@module("viem") external pad: hex => hex = "pad"

type sizeOptions = {size: int}
@module("viem") external bigintToHex: (bigint, ~options: sizeOptions=?) => hex = "numberToHex"
@module("viem") external stringToHex: (string, ~options: sizeOptions=?) => hex = "stringToHex"
@module("viem") external boolToHex: (bool, ~options: sizeOptions=?) => hex = "boolToHex"
@module("viem") external bytesToHex: (Uint8Array.t, ~options: sizeOptions=?) => hex = "bytesToHex"
@module("viem") external concat: array<hex> => hex = "concat"

type abiParams
@module("viem") external parseAbiParameters: string => abiParams = "parseAbiParameters"
@module("viem")
external encodeAbiParametersUnsafe: (abiParams, array<'a>) => hex = "encodeAbiParameters"
