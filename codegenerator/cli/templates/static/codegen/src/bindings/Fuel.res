@genType.import(("./OpaqueTypes.ts", "EthersAddress"))
type fuelAddress = Ethers.ethAddress

module Address = {
  type t = fuelAddress

  let toString: fuelAddress => string = address => address->Utils.magic
  let fromString: string => fuelAddress = addressStr => addressStr->Utils.magic
}

@genType
type receiptType = | @as(6) LogData
type fuelBytes256 = string
type fuelTxId = fuelBytes256

@module("./vendored-fuel-abi-coder.js") @scope("AbiCoder")
external getLogDecoder: (~abi: Ethers.abi, ~logId: string) => (. string) => unknown =
  "getLogDecoder"

module Receipt = {
  @tag("receiptType")
  type t = | @as(6) LogData({data: string, rb: bigint})

  let getLogDataDecoder = (~abi: Ethers.abi, ~logId: string) => {
    let decode = getLogDecoder(~abi, ~logId)
    (receipt: t) => (receipt->Utils.magic)["data"]->decode->Utils.magic
  }

  let unitDecoder = {(_: t) => ()}
}
