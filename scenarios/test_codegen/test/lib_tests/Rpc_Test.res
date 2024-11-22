open RescriptMocha
open Belt

describe_skip("Rpc Test", () => {
  let rpcUrl = "https://eth.llamarpc.com"
  Async.it("Executes single getBlockByNumber rpc call and parses response", async () => {
    let res = await QueryHelpers.executeFetchRequest(
      ~endpoint=rpcUrl,
      ~method=#POST,
      ~bodyAndSchema=(Rpc.GetBlockByNumber.make(~blockNumber=1), Rpc.Query.schema),
      ~responseSchema=Rpc.GetBlockByNumber.responseSchema,
      // ~responseSchema=S.json(~validate=false),
    )

    Assert.ok(res->Result.isOk, ~message="Failed getting block by number")
    let result = Result.getExn(res).result
    Assert.ok(result->Option.isSome, ~message="Block 0 should exist on mainnet")

    let result = Result.getExn(res).result->Option.getExn
    Assert.equal(result.number, 1, ~message="Block number should be 1")
  })

  Async.it("Gets block height from rpc", async () => {
    let res = await QueryHelpers.executeFetchRequest(
      ~endpoint=rpcUrl,
      ~method=#POST,
      ~bodyAndSchema=(Rpc.GetBlockHeight.make(), Rpc.Query.schema),
      // ~responseSchema=S.json(~validate=false),
      ~responseSchema=Rpc.GetBlockHeight.responseSchema,
    )

    Assert.ok(res->Result.isOk, ~message="Failed getting block height")
    Assert.ok(Result.getExn(res).result > 0, ~message="Block height should be greater than 0")
  })

  Async.it("GetLogs rpc call wildcard call", async () => {
    let res = await QueryHelpers.executeFetchRequest(
      ~endpoint=rpcUrl,
      ~method=#POST,
      ~bodyAndSchema=(
        Rpc.GetLogs.make(
          ~fromBlock=20742567,
          ~toBlock=20742567,
          ~address=[],
          ~topics=[Single("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")],
        ),
        Rpc.Query.schema,
      ),
      ~responseSchema=Rpc.GetLogs.responseSchema,
    )
    Assert.ok(res->Result.isOk, ~message="Failed getting logs")
    let res = Result.getExn(res).result
    Assert.equal(res->Array.length, 88, ~message="Should have 88 transfer logs")
  })

  Async.it("GetLogs rpc call with address", async () => {
    let res = await QueryHelpers.executeFetchRequest(
      ~endpoint=rpcUrl,
      ~method=#POST,
      ~bodyAndSchema=(
        Rpc.GetLogs.make(
          ~fromBlock=20742567,
          ~toBlock=20742567,
          ~address=["0xF57e7e7C23978C3cAEC3C3548E3D615c346e79fF"->Address.Evm.fromStringOrThrow],
          ~topics=[Single("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")],
        ),
        Rpc.Query.schema,
      ),
      ~responseSchema=Rpc.GetLogs.responseSchema,
    )

    Assert.ok(res->Result.isOk, ~message="Failed getting logs")
    let res = Result.getExn(res).result
    Assert.equal(res->Array.length, 1, ~message="Should have 1 transfer logs")
  })
})
