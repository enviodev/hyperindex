open RescriptMocha
open Mocha

describe("Parsing Raw Events", () => {
  it("Parses a raw event entity into a batch queue item", () => {
    let params: Types.GravatarContract.NewGravatarEvent.eventArgs = {
      id: 1->Ethers.BigInt.fromInt,
      owner: "0xc944E90C64B2c07662A292be6244BDf05Cda44a7"->Ethers.getAddressFromStringUnsafe,
      displayName: "Testname",
      imageUrl: "myurl.com",
    }

    let paramsEncoded =
      params->Types.GravatarContract.NewGravatarEvent.eventArgs_encode->Js.Json.stringify

    let blockNumber = 11954567
    let timestamp = 1614631579
    let chainId = 1
    let logIndex = 71
    let blockHash = "0x826bdba07d8f295ef4a0a55c342b49d75699a7c2088a1afa8d71cd33b558fd71"
    let srcAddress = Ethers.getAddressFromStringUnsafe("0xc944E90C64B2c07662A292be6244BDf05Cda44a7")
    let transactionHash = "0x4637e2c771f4a3543a91add8d12d7d189cd98cc7ad36c39bc3ea5f57832e84d4"
    let transactionIndex = 66

    let mockRawEventsEntity: Types.rawEventsEntity = {
      blockNumber,
      blockTimestamp: timestamp,
      chainId,
      eventId: "783454502983",
      transactionIndex,
      logIndex,
      transactionHash,
      srcAddress,
      eventType: Js.Json.string("Gravatar_NewGravatar"),
      blockHash,
      params: paramsEncoded,
    }

    let parsedEvent = mockRawEventsEntity->Converters.parseRawEvent->Belt.Result.getExn

    let expectedParseResult: Types.eventBatchQueueItem = {
      timestamp: 1614631579,
      chainId,
      blockNumber,
      logIndex,
      event: Types.GravatarContract_NewGravatar({
        blockNumber,
        blockTimestamp: timestamp,
        blockHash,
        srcAddress,
        transactionHash,
        transactionIndex,
        logIndex,
        params,
      }),
    }

    Assert.deep_strict_equal(parsedEvent, expectedParseResult)
  })
})
