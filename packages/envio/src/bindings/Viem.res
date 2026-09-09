type hex = EvmTypes.Hex.t
@module("viem") external toHex: 'a => hex = "toHex"
@module("viem") external pad: hex => hex = "pad"

type sizeOptions = {size: int}
@module("viem") external bigintToHex: (bigint, ~options: sizeOptions=?) => hex = "numberToHex"
