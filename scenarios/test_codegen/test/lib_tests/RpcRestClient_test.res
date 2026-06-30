open Vitest

describe("Rpc.makeClient - headers", () => {
  Async.it("Sends configured custom headers with the request", async t => {
    let mock = await MockRpcServer.makeRaw(
      ~status=200,
      ~body=`{"jsonrpc":"2.0","id":1,"result":null}`,
    )
    let client = Rpc.makeClient(
      mock.url,
      ~headers=Dict.fromArray([("Authorization", "Bearer rest-token")]),
    )

    let _ = try await Rpc.GetBlockByNumber.route->Rest.fetch(
      {"blockNumber": 1, "includeTransactions": false},
      ~client,
    ) catch {
    | _ => None
    }
    mock.close()

    // Node lowercases header names on the way in.
    t.expect(mock.requestHeaders->Array.getUnsafe(0)->Dict.get("authorization")).toEqual(
      Some("Bearer rest-token"),
    )
  })
})
