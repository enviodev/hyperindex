type receiptType =
  | @as(0) Call
  | @as(1) Return
  | @as(2) ReturnData
  | @as(3) Panic
  | @as(4) Revert
  | @as(5) Log
  | @as(6) LogData
  // Transfer is to another contract, TransferOut is to wallet address
  | @as(7) Transfer
  | @as(8) TransferOut
  | @as(9) ScriptResult
  | @as(10) MessageOut
  | @as(11) Mint
  | @as(12) Burn

@module("./vendored-fuel-abi-coder.js")
external transpileAbi: Js.Json.t => Ethers.abi = "transpileAbi"

@module("./vendored-fuel-abi-coder.js") @scope("AbiCoder")
external getLogDecoder: (~abi: Ethers.abi, ~logId: string) => string => unknown = "getLogDecoder"

module Receipt = {
  @tag("receiptType")
  type t =
    | @as(0) Call({assetId: string, amount: bigint, to: string})
    | @as(6) LogData({data: string, rb: bigint})
    | @as(7) Transfer({amount: bigint, assetId: string, to: string})
    | @as(8) TransferOut({amount: bigint, assetId: string, toAddress: string})
    | @as(11) Mint({val: bigint, subId: string})
    | @as(12) Burn({val: bigint, subId: string})

  let getLogDataDecoder = (~abi: Ethers.abi, ~logId: string) => {
    let decode = getLogDecoder(~abi, ~logId)
    data => data->decode->Utils.magic
  }
}
