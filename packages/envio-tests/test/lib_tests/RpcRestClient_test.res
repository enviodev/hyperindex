open Vitest

describe("Rpc.makeClient - headers", () => {
  Async.it("Sends configured custom headers with the request", async t => {
    await MockRpcServer.withScenario(
      ~name="ReScript REST client custom headers",
      ~calls=[
        MockRpcServer.expectCall(
          ~method="eth_getBlockByNumber",
          ~params=JSON.parseOrThrow(`["0x1",false]`),
          ~headers=Dict.fromArray([("authorization", "Bearer rest-token")]),
          ~reply=RpcResult(JSON.Null),
        ),
      ],
      async mock => {
        let client = Rpc.makeClient(
          mock.url,
          ~headers=Dict.fromArray([("Authorization", "Bearer rest-token")]),
        )
        let result = await Rpc.GetBlockByNumber.route->Rest.fetch(
          {"blockNumber": 1, "includeTransactions": false},
          ~client,
        )
        t.expect(result).toEqual(None)
      },
    )
  })
})
