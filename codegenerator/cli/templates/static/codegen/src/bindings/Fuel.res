// 0 = Call
// 1 = Return,
// 2 = ReturnData,
// 3 = Panic,
// 4 = Revert,
// 5 = Log,
// 6 = LogData,
// 7 = Transfer,
// 8 = Transferout,
// 9 = ScriptResult,
// 10 = MessageOut,
// 11 = Mint,
// 12 = Burn,
type receiptType = | @as(6) LogData | @as(8) TransferOut | @as(11) Mint | @as(12) Burn

@module("./vendored-fuel-abi-coder.js")
external transpileAbi: Js.Json.t => Ethers.abi = "transpileAbi"

@module("./vendored-fuel-abi-coder.js") @scope("AbiCoder")
external getLogDecoder: (~abi: Ethers.abi, ~logId: string) => (. string) => unknown =
  "getLogDecoder"

module Receipt = {
  @tag("receiptType")
  type t =
    | @as(6) LogData({data: string, rb: bigint})
    | @as(8) TransferOut({amount: bigint, assetId: string, toAddress: string})
    | @as(11) Mint({val: bigint, subId: string})
    | @as(12) Burn({val: bigint, subId: string})

  let getLogDataDecoder = (~abi: Ethers.abi, ~logId: string) => {
    let decode = getLogDecoder(~abi, ~logId)
    data => data->decode->Utils.magic
  }
}
