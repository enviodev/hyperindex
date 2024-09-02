open Belt
open RescriptMocha

let config = RegisterHandlers.getConfig()

module Mock = {
  /*

  Block creates a user
  Block that removes a user
*/
  let makeTransferMock = (~from, ~to, ~value): Types.ERC20.Transfer.eventArgs => {
    from,
    to,
    value: value->BigInt.fromInt,
  }

  let makeDeleteUserMock = (~user): Types.ERC20Factory.DeleteUser.eventArgs => {
    user: user,
  }

  let mintAddress = Ethers.Constants.zeroAddress
  let userAddress1 = Ethers.Addresses.mockAddresses[1]->Option.getExn
  let userAddress2 = Ethers.Addresses.mockAddresses[2]->Option.getExn

  let mint50ToUser1 = makeTransferMock(~from=mintAddress, ~to=userAddress1, ~value=50)
  let transfer10User1ToUser2 = makeTransferMock(~from=userAddress1, ~to=userAddress2, ~value=10)
  let deleteUser1 = makeDeleteUserMock(~user=userAddress1)

  let addBlocksOfTransferEvents = (
    blocksOfTransferEventParams,
    ~mockChainData,
    ~mkTransferEventConstr,
  ) =>
    blocksOfTransferEventParams->Array.reduce(mockChainData, (accum, next) => {
      let makeLogConstructors = next->Array.map(mkTransferEventConstr)
      accum->MockChainData.addBlock(~makeLogConstructors)
    })

  module Chain1 = {
    include RollbackMultichain_test.Mock.Chain1

    let factoryAddress = ChainDataHelpers.ERC20Factory.getDefaultAddress(chain)

    open ChainDataHelpers.ERC20
    open ChainDataHelpers.ERC20Factory
    let mkTransferEventConstr = Transfer.mkEventConstrWithParamsAndAddress(
      ~srcAddress=ChainDataHelpers.ERC20.getDefaultAddress(chain),
      ~params=_,
      ...
    )
    let mkDeletUserEventConstr = DeleteUser.mkEventConstrWithParamsAndAddress(
      ~srcAddress=factoryAddress,
      ~params=_,
      ...
    )

    let b0 = []
    let b1 = [mint50ToUser1->mkTransferEventConstr, transfer10User1ToUser2->mkTransferEventConstr]
    let b2 = []
    let b3 = [deleteUser1->mkDeletUserEventConstr, transfer10User1ToUser2->mkTransferEventConstr]

    let blocks = [b0, b1, b2, b3]

    let mockChainData = blocks->Array.reduce(mockChainDataEmpty, (accum, makeLogConstructors) => {
      accum->MockChainData.addBlock(~makeLogConstructors)
    })
  }
  module Chain2 = RollbackMultichain_test.Mock.Chain2

  let mockChainDataMap = config.chainMap->ChainMap.mapWithKey((chain, _) =>
    switch chain->ChainMap.Chain.toChainId {
    | 1 => Chain1.mockChainData
    | 137 => Chain2.mockChainDataEmpty
    | _ => Js.Exn.raiseError("Unexpected chain")
    }
  )

  let getUpdateEndofBlockRangeScannedData = (
    mcdMap,
    ~chain,
    ~blockNumber,
    ~blockNumberThreshold,
    ~blockTimestampThreshold,
  ) => {
    let {blockNumber, blockTimestamp, blockHash} =
      mcdMap->ChainMap.get(chain)->MockChainData.getBlock(~blockNumber)->Option.getUnsafe

    GlobalState.UpdateEndOfBlockRangeScannedData({
      blockNumberThreshold,
      blockTimestampThreshold,
      chain,
      nextEndOfBlockRangeScannedData: {
        blockNumber,
        blockHash,
        blockTimestamp,
        chainId: chain->ChainMap.Chain.toChainId,
      },
    })
  }
}

module Sql = RollbackMultichain_test.Sql

describe("Tests where eq queries", () => {
  Async.before(() => {
    //Provision the db
    DbHelpers.runUpDownMigration()
  })

  Async.it("Where Eq query returns values and removes after inmemory delete", async () => {
    //Setup a chainManager with unordered multichain mode to make processing happen
    //without blocking for the purposes of this test
    let chainManager = {
      ...ChainManager.makeFromConfig(~config, ~maxAddrInPartition=Env.maxAddrInPartition),
      isUnorderedMultichainMode: true,
    }

    let loadLayer = LoadLayer.makeWithDbConnection()

    //Setup initial state stub that will be used for both
    //initial chain data and reorg chain data
    let initState = GlobalState.make(~config, ~chainManager, ~loadLayer)
    let gsManager = initState->GlobalStateManager.make
    let tasks = ref([])
    let makeStub = ChainDataHelpers.Stubs.make(~gsManager, ~tasks, ...)

    open ChainDataHelpers
    //Stub specifically for using data from then initial chain data and functions
    let stubDataInitial = makeStub(~mockChainDataMap=Mock.mockChainDataMap)
    let dispatchTask = Stubs.makeDispatchTask(stubDataInitial, _)
    let dispatchAllTasks = () => stubDataInitial->Stubs.dispatchAllTasks

    //Dispatch first task of next query all chains
    //First query will just get the height
    await dispatchTask(NextQuery(CheckAllChains))

    Assert.deepEqual(
      [GlobalState.NextQuery(Chain(Mock.Chain1.chain)), NextQuery(Chain(Mock.Chain2.chain))],
      stubDataInitial->Stubs.getTasks,
      ~message="Should have completed query to get height, next tasks would be to execute block range query",
    )

    await dispatchAllTasks()
    await dispatchAllTasks()
    Assert.equal(
      EventHandlers.whereEqFromAccountTest.contents->Array.length,
      1,
      ~message="should have successfully loaded values on where eq address query",
    )
    Assert.equal(
      EventHandlers.whereEqBigNumTest.contents->Array.length,
      1,
      ~message="should have successfully loaded values on where eq bigint query",
    )
    let users = await Sql.getAllRowsInTable("Account")
    Assert.equal(users->Array.length, 3, ~message="Should contain user1, user2 and minter address")
    await dispatchAllTasks()
    Assert.equal(
      EventHandlers.whereEqFromAccountTest.contents->Array.length,
      0,
      ~message="should have removed index on deleted user",
    )
  })
})
