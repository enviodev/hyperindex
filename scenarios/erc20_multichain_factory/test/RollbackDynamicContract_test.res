open Belt
// open RescriptMocha

let config = RegisterHandlers.getConfig()

module Mock = {
  /*

  blocks of 3 queried

0a
1a nothing just to get block hashes (adds end of range A block hash)

2b 
3b register contract (dynamic query should action from 3, where parent hash is block 2 not 3)
ensure that this doesn't trigger a reorg
*/
  let makeTransferMock = (~from, ~to, ~value): Types.ERC20.Transfer.eventArgs => {
    from,
    to,
    value: value->BigInt.fromInt,
  }

  let makeTokenCreatedMock = (~token): Types.ERC20Factory.TokenCreated.eventArgs => {
    token: token,
  }

  let mintAddress = Ethers.Constants.zeroAddress
  let userAddress1 = Ethers.Addresses.mockAddresses[1]->Option.getExn
  let userAddress2 = Ethers.Addresses.mockAddresses[2]->Option.getExn

  let mockDyamicToken1 = Ethers.Addresses.mockAddresses[3]->Option.getExn

  let deployToken1 = makeTokenCreatedMock(~token=mockDyamicToken1)

  let mint50ToUser1 = makeTransferMock(~from=mintAddress, ~to=userAddress1, ~value=50)
  let mint100ToUser2 = makeTransferMock(~from=mintAddress, ~to=userAddress2, ~value=100)
  //mock transfers from user 2 to user 1
  let transfer20FromU2ToU1 = makeTransferMock(~from=userAddress2, ~to=userAddress1, ~value=20)
  let transfer30FromU2ToU1 = makeTransferMock(~from=userAddress2, ~to=userAddress1, ~value=30)
  let transfer19FromU2ToU1 = makeTransferMock(~from=userAddress2, ~to=userAddress1, ~value=19)

  //mock transfers from user 1 to user 2
  let transfer15FromU1ToU2 = makeTransferMock(~from=userAddress1, ~to=userAddress2, ~value=15)
  let transfer8FromU1ToU2 = makeTransferMock(~from=userAddress1, ~to=userAddress2, ~value=8)
  let transfer6FromU1ToU2 = makeTransferMock(~from=userAddress1, ~to=userAddress2, ~value=6)

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
    let mkTransferEventConstr = params =>
      Transfer.mkEventConstrWithParamsAndAddress(
        ~srcAddress=mockDyamicToken1,
        ~params=params->(Utils.magic: Types.ERC20.Transfer.eventArgs => Internal.eventParams),
        ...
      )
    let mkTokenCreatedEventConstr = params =>
      TokenCreated.mkEventConstrWithParamsAndAddress(
        ~srcAddress=factoryAddress,
        ~params=params->(
          Utils.magic: Types.ERC20Factory.TokenCreated.eventArgs => Internal.eventParams
        ),
        ...
      )

    let b0 = []
    let b1 = []
    let b2 = []
    let b3 = [deployToken1->mkTokenCreatedEventConstr]
    let b4 = [mint50ToUser1->mkTransferEventConstr]
    let b5 = []
    let b6 = []

    let blocks = [b0, b1, b2, b3, b4, b5, b6]

    let mockChainData = blocks->Array.reduce(mockChainDataEmpty, (accum, makeLogConstructors) => {
      accum->MockChainData.addBlock(~makeLogConstructors)
    })
  }
  module Chain2 = RollbackMultichain_test.Mock.Chain2

  let mockChainDataMap = config.chainMap->ChainMap.mapWithKey((chain, _) =>
    switch chain->ChainMap.Chain.toChainId {
    | 1 => Chain1.mockChainData
    | 137 => Chain2.mockChainData
    | _ => Js.Exn.raiseError("Unexpected chain")
    }
  )

  let getUpdateEndofBlockRangeScannedData = (
    mcdMap,
    ~chain,
    ~blockNumber,
    ~blockNumberThreshold,
  ) => {
    let {blockNumber, blockHash} =
      mcdMap->ChainMap.get(chain)->MockChainData.getBlock(~blockNumber)->Option.getUnsafe

    GlobalState.UpdateEndOfBlockRangeScannedData({
      blockNumberThreshold,
      chain,
      nextEndOfBlockRangeScannedData: {
        blockNumber,
        blockHash,
        chainId: chain->ChainMap.Chain.toChainId,
      },
    })
  }
}

module Sql = RollbackMultichain_test.Sql

// The test is too difficult to maintain
// describe("Dynamic contract rollback test", () => {
//   Async.before(() => {
//     //Provision the db
//     DbHelpers.runUpDownMigration()
//   })

//   Async.it("Dynamic contract should not trigger reorg", async () => {
//     //Setup a chainManager with unordered multichain mode to make processing happen
//     //without blocking for the purposes of this test
//     let chainManager = {
//       ...ChainManager.makeFromConfig(~config),
//       isUnorderedMultichainMode: true,
//     }

//     let loadLayer = LoadLayer.makeWithDbConnection()

//     //Setup initial state stub that will be used for both
//     //initial chain data and reorg chain data
//     let initState = GlobalState.make(~config, ~chainManager, ~loadLayer)
//     let gsManager = initState->GlobalStateManager.make
//     let tasks = ref([])
//     let makeStub = ChainDataHelpers.Stubs.make(~gsManager, ~tasks, ...)

//     //helpers
//     let getChainFetcher = chain => {
//       let state = gsManager->GlobalStateManager.getState
//       state.chainManager.chainFetchers->ChainMap.get(chain)
//     }

//     let getFetchState = chain => {
//       let cf = chain->getChainFetcher
//       cf.fetchState
//     }

//     let getLatestFetchedBlock = chain => {
//       chain->getFetchState->FetchState.getLatestFullyFetchedBlock
//     }

//     let getTokenBalance = (~accountAddress) => chain => {
//       Sql.getAccountTokenBalance(
//         ~tokenAddress=ChainDataHelpers.ERC20.getDefaultAddress(chain),
//         ~accountAddress,
//       )
//     }

//     let getUser1Balance = getTokenBalance(~accountAddress=Mock.userAddress1)
//     let getUser2Balance = getTokenBalance(~accountAddress=Mock.userAddress2)

//     let getTotalQueueSize = () => {
//       let state = gsManager->GlobalStateManager.getState
//       state.chainManager.chainFetchers
//       ->ChainMap.values
//       ->Array.reduce(
//         0,
//         (accum, chainFetcher) => accum + chainFetcher.fetchState->FetchState.queueSize,
//       )
//     }

//     open ChainDataHelpers
//     //Stub specifically for using data from then initial chain data and functions
//     let stubDataInitial = makeStub(~mockChainDataMap=Mock.mockChainDataMap)
//     let dispatchTask = Stubs.makeDispatchTask(stubDataInitial, _)
//     let dispatchAllTasks = () => stubDataInitial->Stubs.dispatchAllTasks

//     //Dispatch first task of next query all chains
//     //First query will just get the height
//     await dispatchTask(NextQuery(CheckAllChains))

//     Assert.deepEqual(
//       stubDataInitial->Stubs.getTasks,
//       [GlobalState.NextQuery(Chain(Mock.Chain1.chain)), NextQuery(Chain(Mock.Chain2.chain))],
//       ~message="Should have completed query to get height, next tasks would be to execute block range query",
//     )

//     let makeAssertions = async (
//       ~queryName,
//       ~chain1LatestFetchBlock,
//       ~chain2LatestFetchBlock,
//       ~totalQueueSize,
//       ~batchName,
//       ~chain1User1Balance,
//       ~chain1User2Balance,
//       ~chain2User1Balance,
//       ~chain2User2Balance,
//     ) => {
//       Assert.equal(
//         getLatestFetchedBlock(Mock.Chain1.chain).blockNumber,
//         chain1LatestFetchBlock,
//         ~message=`Chain 1 should have fetched up to block ${chain1LatestFetchBlock->Int.toString} on query ${queryName}`,
//       )
//       Assert.equal(
//         getLatestFetchedBlock(Mock.Chain2.chain).blockNumber,
//         chain2LatestFetchBlock,
//         ~message=`Chain 2 should have fetched up to block ${chain2LatestFetchBlock->Int.toString} on query ${queryName}`,
//       )
//       Assert.equal(
//         getTotalQueueSize(),
//         totalQueueSize,
//         ~message=`Query ${queryName} should have returned ${totalQueueSize->Int.toString} events`,
//       )

//       let toBigInt = BigInt.fromInt
//       let optIntToString = optInt =>
//         switch optInt {
//         | Some(n) => `Some(${n->Int.toString})`
//         | None => "None"
//         }

//       let getBalanceFn = (chain, user) =>
//         switch user {
//         | 1 => chain->getUser1Balance
//         | 2 => chain->getUser2Balance
//         | user => Js.Exn.raiseError(`Invalid user num ${user->Int.toString}`)
//         }

//       let assertBalance = async (~chain, ~expectedBalance, ~user) => {
//         let balance = await getBalanceFn(chain, user)
//         Assert.deepEqual(
//           balance,
//           expectedBalance->Option.map(toBigInt),
//           ~message=`Chain ${chain->ChainMap.Chain.toString} after processing blocks in batch ${batchName}, User ${user->Int.toString} should have a balance of ${expectedBalance->optIntToString} but has ${balance
//             ->Option.flatMap(BigInt.toInt)
//             ->optIntToString}`,
//         )
//       }
//       //Chain 1 balances
//       await assertBalance(~chain=Mock.Chain1.chain, ~user=1, ~expectedBalance=chain1User1Balance)
//       await assertBalance(~chain=Mock.Chain1.chain, ~user=2, ~expectedBalance=chain1User2Balance)
//       await assertBalance(~chain=Mock.Chain2.chain, ~user=1, ~expectedBalance=chain2User1Balance)
//       await assertBalance(~chain=Mock.Chain2.chain, ~user=2, ~expectedBalance=chain2User2Balance)
//     }

//     await makeAssertions(
//       ~queryName="No Query",
//       ~chain1LatestFetchBlock=0,
//       ~chain2LatestFetchBlock=0,
//       ~totalQueueSize=0,
//       ~batchName="No Batch",
//       ~chain1User1Balance=None,
//       ~chain1User2Balance=None,
//       ~chain2User1Balance=None,
//       ~chain2User2Balance=None,
//     )

//     //Make the first queries (A)
//     await dispatchAllTasks()
//     Assert.deepEqual(
//       stubDataInitial->Stubs.getTasks,
//       [
//         Mock.getUpdateEndofBlockRangeScannedData(
//           Mock.mockChainDataMap,
//           ~chain=Mock.Chain1.chain,
//           ~blockNumberThreshold=-199,
//           ~blockNumber=1,
//         ),
//         UpdateChainMetaDataAndCheckForExit(NoExit),
//         ProcessEventBatch,
//         NextQuery(Chain(Mock.Chain1.chain)),
//         Mock.getUpdateEndofBlockRangeScannedData(
//           Mock.mockChainDataMap,
//           ~chain=Mock.Chain2.chain,
//           ~blockNumberThreshold=-198,
//           ~blockNumber=2,
//         ),
//         UpdateChainMetaDataAndCheckForExit(NoExit),
//         ProcessEventBatch,
//         NextQuery(Chain(Mock.Chain2.chain)),
//       ],
//       ~message="Should have received a response and next tasks will be to process batch and next query",
//     )

//     await makeAssertions(
//       ~queryName="A",
//       ~chain1LatestFetchBlock=1,
//       ~chain2LatestFetchBlock=2,
//       ~totalQueueSize=2,
//       ~batchName="No Batch",
//       ~chain1User1Balance=None,
//       ~chain1User2Balance=None,
//       ~chain2User1Balance=None,
//       ~chain2User2Balance=None,
//     )

//     //Process the events in the queues
//     //And make queries (B)
//     await dispatchAllTasks()
//     await makeAssertions(
//       ~queryName="B",
//       ~chain1LatestFetchBlock=2,
//       ~chain2LatestFetchBlock=5,
//       ~totalQueueSize=3,
//       ~batchName="A",
//       ~chain1User1Balance=None,
//       ~chain1User2Balance=None,
//       ~chain2User1Balance=Some(50),
//       ~chain2User2Balance=Some(100),
//     )
//     Assert.deepEqual(
//       stubDataInitial->Stubs.getTasks,
//       [
//         NextQuery(CheckAllChains),
//         Mock.getUpdateEndofBlockRangeScannedData(
//           Mock.mockChainDataMap,
//           ~chain=Mock.Chain1.chain,
//           ~blockNumberThreshold=-197,
//           ~blockNumber=3,
//         ),
//         UpdateChainMetaDataAndCheckForExit(NoExit),
//         ProcessEventBatch,
//         NextQuery(Chain(Mock.Chain1.chain)),
//         Mock.getUpdateEndofBlockRangeScannedData(
//           Mock.mockChainDataMap,
//           ~chain=Mock.Chain2.chain,
//           ~blockNumberThreshold=-195,
//           ~blockNumber=5,
//         ),
//         UpdateChainMetaDataAndCheckForExit(NoExit),
//         ProcessEventBatch,
//         NextQuery(Chain(Mock.Chain2.chain)),
//         UpdateChainMetaDataAndCheckForExit(NoExit),
//         ProcessEventBatch,
//         PruneStaleEntityHistory,
//       ],
//       ~message="Should have processed a batch and run next queries on all chains",
//     )

//     //Artificially cut the tasks to only do one round of queries and batch processing
//     tasks := [
//         UpdateChainMetaDataAndCheckForExit(NoExit),
//         ProcessEventBatch,
//         NextQuery(CheckAllChains),
//       ]

//     Assert.deepEqual(
//       getFetchState(Mock.Chain1.chain).partitions->Array.map(p => p.id),
//       ["0", "1"],
//       ~message=`Should have main partition and one dynamic contract partition`,
//     )

//     //Process batch 2 of events
//     //And make queries (C)
//     await dispatchAllTasks()

//     Assert.deepEqual(
//       stubDataInitial->Stubs.getTasks,
//       [
//         GlobalState.NextQuery(CheckAllChains),
//         Mock.getUpdateEndofBlockRangeScannedData(
//           Mock.mockChainDataMap,
//           ~chain=Mock.Chain1.chain,
//           ~blockNumberThreshold=-197,
//           ~blockNumber=3,
//         ),
//         UpdateChainMetaDataAndCheckForExit(NoExit),
//         ProcessEventBatch,
//         NextQuery(Chain(Mock.Chain1.chain)),
//         Mock.getUpdateEndofBlockRangeScannedData(
//           Mock.mockChainDataMap,
//           ~chain=Mock.Chain2.chain,
//           ~blockNumberThreshold=-192,
//           ~blockNumber=8,
//         ),
//         UpdateChainMetaDataAndCheckForExit(NoExit),
//         ProcessEventBatch,
//         NextQuery(Chain(Mock.Chain2.chain)),
//         UpdateChainMetaDataAndCheckForExit(NoExit),
//         ProcessEventBatch,
//         PruneStaleEntityHistory,
//       ],
//       ~message="Next round of tasks after query C",
//     )

//     let partitions = getFetchState(Mock.Chain1.chain).partitions
//     Assert.deepEqual(
//       partitions->Array.map(p => p.id),
//       ["0"],
//       ~message=`DC partition should be merged into main`,
//     )
//     let rootPartition = partitions->Js.Array2.unsafe_get(0)
//     Assert.deepEqual(
//       rootPartition.latestFetchedBlock,
//       {
//         {blockNumber: 3, blockTimestamp: 75}
//       },
//       ~message=`Should get a root partition`,
//     )
//     Assert.deepEqual(
//       rootPartition.addressesByContractName,
//       Js.Dict.fromArray([
//         (
//           "ERC20",
//           [
//             // From Config
//             "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"->Address.unsafeFromString,
//             // From DC
//             "0x90F79bf6EB2c4f870365E785982E1f101E93b906"->Address.unsafeFromString,
//           ],
//         ),
//         // From Config
//         ("ERC20Factory", ["0x8626f6940E2eb28930eFb4CeF49B2d1F2C9C1199"->Address.unsafeFromString]),
//       ]),
//       ~message=`Should have a single dc`,
//     )

//     await makeAssertions(
//       ~queryName="C",
//       ~chain1LatestFetchBlock=3, // Made DC query and merged partitions
//       ~chain2LatestFetchBlock=8,
//       ~totalQueueSize=4,
//       ~batchName="B",
//       ~chain1User1Balance=None,
//       ~chain1User2Balance=None,
//       ~chain2User1Balance=Some(100),
//       ~chain2User2Balance=Some(50),
//     )

//     //Artificially cut the tasks to only do one round of queries and batch processing
//     tasks := [
//         UpdateChainMetaDataAndCheckForExit(NoExit),
//         ProcessEventBatch,
//         NextQuery(CheckAllChains),
//       ]
//     //Process batch 3 of events and make queries
//     //Execute queries(D)
//     await dispatchAllTasks()
//     Assert.deepEqual(
//       [
//         GlobalState.NextQuery(CheckAllChains),
//         Mock.getUpdateEndofBlockRangeScannedData(
//           Mock.mockChainDataMap,
//           ~chain=Mock.Chain1.chain,
//           ~blockNumberThreshold=-195,
//           ~blockNumber=5,
//         ),
//         UpdateChainMetaDataAndCheckForExit(NoExit),
//         ProcessEventBatch,
//         NextQuery(Chain(Mock.Chain1.chain)),
//         Mock.getUpdateEndofBlockRangeScannedData(
//           Mock.mockChainDataMap,
//           ~chain=Mock.Chain2.chain,
//           ~blockNumberThreshold=-191,
//           ~blockNumber=9,
//         ),
//         UpdateChainMetaDataAndCheckForExit(NoExit),
//         ProcessEventBatch,
//         NextQuery(Chain(Mock.Chain2.chain)),
//         UpdateChainMetaDataAndCheckForExit(NoExit),
//         ProcessEventBatch,
//         PruneStaleEntityHistory,
//       ],
//       stubDataInitial->Stubs.getTasks,
//       ~message="Next round of tasks after query D",
//     )

//     await makeAssertions(
//       ~queryName="D",
//       ~chain1LatestFetchBlock=5,
//       ~chain2LatestFetchBlock=9,
//       ~totalQueueSize=2, //One from dynamic contract, one from 137
//       ~batchName="C",
//       ~chain1User1Balance=None,
//       ~chain1User2Balance=None,
//       ~chain2User1Balance=Some(98),
//       ~chain2User2Balance=Some(52),
//     )

//     //Artificially cut the tasks to only do one round of queries and batch processing
//     tasks := [
//         UpdateChainMetaDataAndCheckForExit(NoExit),
//         ProcessEventBatch,
//         NextQuery(CheckAllChains),
//       ]
//     //Process batch 2 of events and make queries
//     //Execute queries(E)
//     await dispatchAllTasks()
//     Assert.equal(
//       stubDataInitial->Stubs.getTasks->Js.Array2.includes(Rollback),
//       false,
//       ~message="dynamic contract query should not action rollback",
//     )
//   })
// })
