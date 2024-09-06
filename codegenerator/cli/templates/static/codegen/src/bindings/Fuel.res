type receiptType = | @as(6) LogData

@module("./vendored-fuel-abi-coder.js")
external transpileAbi: Js.Json.t => Ethers.abi = "transpileAbi"

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

  let unitDecoder = (_: t) => ()
}
