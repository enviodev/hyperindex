open RescriptMocha

describe_skip("Rpc Test", () => {
  // let rpcUrl = "https://eth.rpc.hypersync.xyz"
  let rpcUrl = "https://eth.llamarpc.com"

  let client = Rest.client(rpcUrl)

  Async.it("Executes single getBlockByNumber rpc call and parses response", async () => {
    let maybeBlock = await Rpc.GetBlockByNumber.route->Rest.fetch(
      {
        "blockNumber": 1,
        "includeTransactions": false,
      },
      ~client,
    )

    Assert.deepEqual(
      maybeBlock,
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

  Async.it("Gets block height from rpc", async () => {
    let height = await Rpc.GetBlockHeight.route->Rest.fetch((), ~client)

    Assert.ok(
      height > 21244092,
      ~message=`Block height should be greater than 21244092. Received ${height->Int.toString}`,
    )
  })

  Async.it("GetLogs rpc call wildcard call", async () => {
    let logs = await Rpc.GetLogs.route->Rest.fetch(
      {
        fromBlock: 20742567,
        toBlock: 20742567,
        address: [],
        topics: [Single("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")],
      },
      ~client,
    )

    Assert.deepEqual(logs->Array.length, 88, ~message="Should have 88 transfer logs")
  })

  Async.it("GetLogs rpc call with address", async () => {
    let logs = await Rpc.GetLogs.route->Rest.fetch(
      {
        fromBlock: 20742567,
        toBlock: 20742567,
        address: ["0xF57e7e7C23978C3cAEC3C3548E3D615c346e79fF"->Address.Evm.fromStringOrThrow],
        topics: [Single("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")],
      },
      ~client,
    )

    Assert.deepEqual(
      logs,
      [
        {
          address: "0xf57e7e7c23978c3caec3c3548e3d615c346e79ff"->Address.unsafeFromString,
          blockHash: "0xd6b9a4d49a8ae1af5a13d2de596d0c045ec80b2cc41754ff09547521eca7bf66",
          blockNumber: 20742567,
          data: "0x000000000000000000000000000000000000000000000009c2007651b2500000",
          logIndex: 125,
          removed: false,
          topics: [
            "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
            "0x00000000000000000000000074dec05e5b894b0efec69cdf6316971802a2f9a1",
            "0x0000000000000000000000008eadea389180f8d21393d6c7e9a914b4bb23cbca",
          ],
          transactionHash: "0x32461781e65b36f321fb8c9532a2729d6e16026a8f5b242401ff9993ddc0bf27",
          transactionIndex: 101,
        },
      ],
      ~message="Should have 1 transfer logs",
    )
  })
})
