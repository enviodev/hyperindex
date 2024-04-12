open Belt
open RescriptMocha
open Mocha
let {
  it: it_promise,
  it_only: it_promise_only,
  it_skip: it_skip_promise,
  before: before_promise,
} = module(RescriptMocha.Promise)

module Mock = {
  /*
  Chain 1 has 6 blocks in 25s intervals and getting batches of 2 blocks at a time
  Chain 2 has 9 blocks at 16s intervals and getting bathes of 3 blocks at a time
  Chain 1 fetches all the way up to 5c
  A reorg occurs on chain1 affecting blocks 4 and onwards.
  on query for block range d a reorg is detected and should rollback to the end of query b (block 3 the nearest known valid block) 
  and start query c again.
  Chain 2 should follow suit and rollback to nearest known endOfRange block (2a), actioning query b again
  Chain 2 blocks 3 and 4 would not have been affeced by rollback so we should not be double processing those events
  | time | c1  | c2
  | 0    |  0a | 0a
  | 16   |     | 1a
  | 25   |  1a |
  | 32   |     | 2a
  | 48   |     | 3b
  | 50   |  2b |
  | 64   |     | 4b
  | 75   |  3b | 
  | 80   |     | 5b
  | 96   |     | 6c
  | 100  |  4c |
  | 112  |     | 7c
  | 125  |  5c |
  | 128  |     | 8c
  | 144  |     | 9d
  | 150  |  6d |
 */
  let makeTransferMock = (~from, ~to, ~value): Types.ERC20Contract.TransferEvent.eventArgs => {
    from,
    to,
    value: value->Ethers.BigInt.fromInt,
  }

  let mintAddress = Ethers.Constants.zeroAddress
  let userAddress1 = Ethers.Addresses.mockAddresses[1]->Option.getExn
  let userAddress2 = Ethers.Addresses.mockAddresses[2]->Option.getExn

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
    let chain = ChainMap.Chain.Chain_1
    let mockChainDataEmpty = MockChainData.make(
      ~chainConfig=Config.config->ChainMap.get(chain),
      ~maxBlocksReturned=3,
      ~blockTimestampInterval=25,
    )

    open ChainDataHelpers.ERC20
    let mkTransferEventConstr = Transfer.mkEventConstr(~chain)

    let b0 = []
    //balances: u1=0 | u2=0
    let b1 = [mint50ToUser1]
    //balances: u1=50 | u2=0
    let b2 = [mint100ToUser2]
    //balances: u1=50 | u2=100
    let b3 = []
    let b4 = [transfer30FromU2ToU1] //<-- blockhash should change from here after reorg
    //balances before rollback: u1=80 | u2=70
    let rollbackB4 = [transfer19FromU2ToU1]
    //balances after rollback: u1=69 | u2=81
    let b5 = [transfer20FromU2ToU1]
    //balances before rollback: u1=100 | u2=50
    //balances after rollback: u1=89 | u2=61
    let b6 = [transfer15FromU1ToU2]
    //balances: u1=85 | u2=65
    //balances after rollback: u1=74 | u2=76

    let blocksBase = [b0, b1, b2, b3]
    let blocksInitial = blocksBase->Array.concat([b4, b5, b6])
    let blocksReorg = blocksBase->Array.concat([rollbackB4, b5, b6])

    let applyBlocks = addBlocksOfTransferEvents(
      ~mockChainData=mockChainDataEmpty,
      ~mkTransferEventConstr,
    )

    let mockChainDataInitial = blocksInitial->applyBlocks
    let mockChainDataReorg = blocksReorg->applyBlocks
  }
  module Chain2 = {
    let chain = ChainMap.Chain.Chain_137
    let mockChainDataEmpty = MockChainData.make(
      ~chainConfig=Config.config->ChainMap.get(chain),
      ~maxBlocksReturned=3,
      ~blockTimestampInterval=25,
    )
    open ChainDataHelpers.ERC20
    let mkTransferEventConstr = Transfer.mkEventConstr(~chain)
    let b0 = []
    //balances: u1=0 | u2=0
    let b1 = [mint50ToUser1]
    //balances: u1=50 | u2=0
    let b2 = [mint100ToUser2] //<-- will rollback to here when chain 1 reorgs
    //balances: u1=50 | u2=100
    let b3 = []
    let b4 = [transfer30FromU2ToU1]
    //balances: u1=80 | u2=70
    let b5 = [transfer20FromU2ToU1] //<-- only events from b5 onwards should be reprocessed
    //balances: u1=100 | u2=50
    let b6 = [transfer15FromU1ToU2]
    //balances: u1=85 | u2=65
    let b7 = [transfer6FromU1ToU2, transfer19FromU2ToU1]
    //balances: u1=79 | u2=71 -> u1=98 | u2=52
    let b8 = []
    let b9 = [transfer8FromU1ToU2]
    //balances: u1=90 | u2=60

    let blocks = [b0, b1, b2, b3, b4, b5, b6, b7, b8, b9]

    let applyBlocks = addBlocksOfTransferEvents(
      ~mockChainData=mockChainDataEmpty,
      ~mkTransferEventConstr,
    )

    let mockChainData = blocks->applyBlocks
  }

  let mockChainDataMapInitial = ChainMap.make(chain =>
    switch chain {
    | Chain_1 => Chain1.mockChainDataInitial
    | Chain_137 => Chain2.mockChainData
    }
  )

  let mockChainDataMapReorg = ChainMap.make(chain =>
    switch chain {
    | Chain_1 => Chain1.mockChainDataReorg
    | Chain_137 => Chain2.mockChainData
    }
  )
}

let setupDb = async (~shouldDropRawEvents) => {
  open Migrations
  Logging.info("Provisioning Database")
  let _exitCodeDown = await runDownMigrations(~shouldExit=false, ~shouldDropRawEvents)
  let _exitCodeUp = await runUpMigrations(~shouldExit=false)
}
describe("Multichain rollback test", () => {
  it_promise("Multichain indexer should rollback and not reprocess any events", async () => {
    //Provision the db
    await setupDb(~shouldDropRawEvents=true)

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
    let makeStub = ChainDataHelpers.Stubs.make(~gsManager, ~tasks)

    open ChainDataHelpers
    //Stub specifically for using data from then initial chain data and functions
    let stubDataInitial = makeStub(~mockChainDataMap=Mock.mockChainDataMapInitial)
    let dispatchTask = stubDataInitial->Stubs.makeDispatchTask
    let dispatchAllTasks = () => stubDataInitial->Stubs.dispatchAllTasks

    //Dispatch first task of next query all chains
    //First query will just get the height
    await dispatchTask(NextQuery(CheckAllChains))

    Assert.deep_equal(
      [GlobalState.NextQuery(Chain(Chain_1)), NextQuery(Chain(Chain_137))],
      stubDataInitial->Stubs.getTasks,
      ~message="Should have completed query to get height, next tasks would be to execute block range query",
    )

    //TODO ASSERTIONS
    //Should have fetched up to block zero on both chains
    //Should have no events in queues

    //Make the first queries (A)
    await dispatchAllTasks()
    //TODO ASSERTIONS
    //Should have fetched 2 blocks on chain 1 and 3 on chain 2
    //check for events in queue

    //Process the events in the queues
    //And make queries (B)
    await dispatchAllTasks()
    //TODO Assertions
    //Assert user balances after processing
    //Should have fetched more events

    //Process batch 2 of events
    //And make queries (C)
    await dispatchAllTasks()
    //TODO Assertions
    //Assert user balances after processing
    //Should have fetched more events

    //Chain1 reorgs at block 4
    let stubDataReorg = makeStub(~mockChainDataMap=Mock.mockChainDataMapReorg)
    let dispatchAllTasks = () => stubDataReorg->Stubs.dispatchAllTasks
    //Process batch 3 of events and make queries
    //Execute queries(c)
    await dispatchAllTasks()
    //TODO Assertions
    //Reorg should have been detected

    //Action reorg
    await dispatchAllTasks()
    //Todo assertions
    //Reorg should have been actioned
    //reorg state should have inmemory store
    //Next tasks should be process event
    //Balances should not have changed yet

    //Make new queries (C for Chain 1, B for Chain 2)
    await dispatchAllTasks()
    //Todo assertions
    //events should have come back, assert the number in each queue

    //Process event batch with reorg in mem store and action next queries
    await dispatchAllTasks()
    //Todo assertions
    //Assert new balances


    //Potentially keep going for assertions to end of chain
  })
})
