type hex = EvmTypes.Hex.t

type sizeOptions = {size: int}
@module("viem") external bigintToHex: (bigint, ~options: sizeOptions=?) => hex = "numberToHex"
