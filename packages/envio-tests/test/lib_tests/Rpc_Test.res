open Vitest

describe_skip("Rpc Test", () => {
  // let rpcUrl = "https://eth.rpc.hypersync.xyz"
  let rpcUrl = "https://eth.llamarpc.com"

  let client = Rest.client(rpcUrl)

  Async.it("Executes single getBlockByNumber rpc call and parses response", async t => {
    let maybeBlock = await Rpc.GetBlockByNumber.route->Rest.fetch(
      {
        "blockNumber": 1,
        "includeTransactions": false,
      },
      ~client,
    )

    t.expect(maybeBlock).toEqual(
      Some({
        difficulty: Some(17171480576n),
        extraData: "0x476574682f76312e302e302f6c696e75782f676f312e342e32",
        gasLimit: 5000n,
        gasUsed: 0n,
        hash: "0x88e96d4537bea4d9c05d12549907b32561d3bf31f45aae734cdc119f13406cb6",
        logsBloom: "0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        miner: "0x05a56e2d52c817161883f50c441c3228cfe54d9f"->Address.unsafeFromString, // Not checksummed
        mixHash: Some("0x969b900de27b6ac6a67742365dd65f55a0526c41fd18e1b16f1a1215c2e66f59"),
        nonce: Some(6024642674226568900n),
        number: 1,
        parentHash: "0xd4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3",
        receiptsRoot: "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
        sha3Uncles: "0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347",
        size: 537n,
        stateRoot: "0xd67e4d450343046425ae4271474353857ab860dbc0a1dde64b41b5cd3a532bf3",
        timestamp: 1438269988,
        totalDifficulty: Some(34351349760n),
        transactions: [],
        transactionsRoot: "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
        uncles: Some([]),
      }),
    )
  })
})
