open RescriptMocha
let {it: it_promise, it_skip: it_skip_promise} = module(RescriptMocha.Promise)
open Mocha
//
// describe("Some Test Suite", () =>
//   describe("List.map", () => {
//     it(
//       "should map the values",
//       () => Assert.deep_equal(Array.map([1, 2, 3], i => i * 2), [2, 4, 6]),
//     )
//
//     it("should work with an empty list", () => Assert.deep_equal(Array.map([], i => i * 2), []))
//
//     it_promise(
//       "should be successful",
//       () =>
//         Js.Promise.make(
//           (~resolve, ~reject as _) =>
//             Js.Global.setTimeout(
//               () => {
//                 Assert.equal(3, 3)
//                 resolve(. true)
//               },
//               300,
//             )->ignore,
//         ),
//     )
//   })
// )

describe("E2E Mock Event Batch", () => {
  it_promise("Complete E2E", ~timeout=10000, async () => {
    let gravatar = await SetupRpcNode.deployContract()
    await SetupRpcNode.setupNodeAndContracts(gravatar)
    let provider = Hardhat.hardhatProvider
    let localChainConfig: Config.chainConfig = {
      provider,
      startBlock: 0,
      chainId: 1337,
      contracts: [
        {
          name: "GravatarRegistry",
          abi: Abis.gravatarAbi->Ethers.makeAbi,
          address: "0x5FbDB2315678afecb367f032d93F642f64180aa3"->Ethers.getAddressFromStringUnsafe,
          events: [GravatarContract_NewGravatarEvent, GravatarContract_UpdatedGravatarEvent],
        },
      ],
    }

    RegisterHandlers.registerAllHandlers()
    await localChainConfig->EventSyncing.processAllEvents

    Js.log("starting events subscription")
    let _ = EventSubscription.startWatchingEventsOnRpc(~chainConfig=localChainConfig, ~provider)
    Js.log("submitting transactions")
    await LiveGravatarTask.liveGravatarTxs(gravatar)
    Js.log("finish transactions")
    await Time.resolvePromiseAfterDelay(~delayMilliseconds=5000)
    Js.log("finished")
  })
})
