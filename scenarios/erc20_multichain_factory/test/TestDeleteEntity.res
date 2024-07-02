open Belt
open RescriptMocha

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
  let factoryAddress1 = ChainDataHelpers.ERC20Factory.getDefaultAddress(Chain_1)

  let mint50ToUser1 = makeTransferMock(~from=mintAddress, ~to=userAddress1, ~value=50)
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

    open ChainDataHelpers.ERC20
    open ChainDataHelpers.ERC20Factory
    let mkTransferEventConstr = Transfer.mkEventConstrWithParamsAndAddress(
      ~srcAddress=ChainDataHelpers.ERC20.getDefaultAddress(Chain_1),
      ~params=_,
      ...
    )
    let mkDeletUserEventConstr = DeleteUser.mkEventConstrWithParamsAndAddress(
      ~srcAddress=factoryAddress1,
      ~params=_,
      ...
    )

    let b0 = []
    let b1 = [mint50ToUser1->mkTransferEventConstr]
    let b2 = []
    let b3 = [deleteUser1->mkDeletUserEventConstr]

    let blocks = [b0, b1, b2, b3]

    let mockChainData = blocks->Array.reduce(mockChainDataEmpty, (accum, makeLogConstructors) => {
      accum->MockChainData.addBlock(~makeLogConstructors)
    })
  }
  module Chain2 = RollbackMultichain_test.Mock.Chain2

  let mockChainDataMap = ChainMap.make(chain =>
    switch chain {
    | Chain_1 => Chain1.mockChainData
    | Chain_137 => Chain2.mockChainDataEmpty
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

describe("Unsafe delete test", () => {
  Async.before(() => {
    //Provision the db
    DbHelpers.runUpDownMigration()
  })

  Async.it("Deletes account entity successfully", async () => {
    //Setup a chainManager with unordered multichain mode to make processing happen
    //without blocking for the purposes of this test
    let chainManager = {
      ...ChainManager.makeFromConfig(~configs=Config.config),
      isUnorderedMultichainMode: true,
    }

    //Setup initial state stub that will be used for both
    //initial chain data and reorg chain data
    let initState = GlobalState.make(~chainManager)
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
      [GlobalState.NextQuery(Chain(Chain_1)), NextQuery(Chain(Chain_137))],
      stubDataInitial->Stubs.getTasks,
      ~message="Should have completed query to get height, next tasks would be to execute block range query",
    )

    await dispatchAllTasks()
    await dispatchAllTasks()
    let users = await Sql.getAllRowsInTable("Account")
    Assert.equal(users->Array.length, 2, ~message="Should contain user1 and minter address")
    await dispatchAllTasks()
    let users = await Sql.getAllRowsInTable("Account")
    Assert.equal(users->Array.length, 1, ~message="Should delete user 1")
  })
})
