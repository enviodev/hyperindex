open Vitest

let pubkey = SvmTypes.Pubkey.fromStringUnsafe

describe("EventRouter SVM helpers", () => {
  it("getSvmEventId builds discriminator-keyed tag and falls back to _none", t => {
    let programId = pubkey("metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s")
    let actual = {
      "withDiscriminator": EventRouter.getSvmEventId(
        ~programId,
        ~discriminator=Some("0x0f"),
      ),
      "withoutDiscriminator": EventRouter.getSvmEventId(
        ~programId,
        ~discriminator=None,
      ),
    }
    t.expect(actual).toEqual({
      "withDiscriminator": "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s_0x0f",
      "withoutDiscriminator": "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s_none",
    })
  })

  it("fromSvmEventConfigsOrThrow precomputes per-program discriminator-length ordering desc", t => {
    let chain = ChainMap.Chain.makeUnsafe(~chainId=0)
    let progA = pubkey("metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s")
    let progB = pubkey("11111111111111111111111111111111")
    let mk = (
      ~name,
      ~contractName,
      ~programId,
      ~discriminator,
      ~discriminatorByteLen,
    ): Internal.svmInstructionEventConfig => {
      id: discriminator->Option.getOr("none"),
      name,
      contractName,
      isWildcard: false,
      filterByAddresses: false,
      dependsOnAddresses: true,
      handler: None,
      contractRegister: None,
      paramsRawEventSchema: %raw(`null`),
      simulateParamsSchema: %raw(`null`),
      startBlock: None,
      programId,
      discriminator,
      discriminatorByteLen,
      includeTransaction: true,
      includeLogs: false,
      accountFilters: [],
      isInner: None,
    }
    let configs = [
      mk(
        ~name="One",
        ~contractName="ProgA",
        ~programId=progA,
        ~discriminator=Some("0x0f"),
        ~discriminatorByteLen=1,
      ),
      mk(
        ~name="Eight",
        ~contractName="ProgA",
        ~programId=progA,
        ~discriminator=Some("0x0fffffffffffffff"),
        ~discriminatorByteLen=8,
      ),
      mk(
        ~name="Wide",
        ~contractName="ProgB",
        ~programId=progB,
        ~discriminator=None,
        ~discriminatorByteLen=0,
      ),
    ]
    let (_router, ordering) = EventRouter.fromSvmEventConfigsOrThrow(configs, ~chain)
    let byProgram =
      ordering
      ->Array.map(o => (o.programId->SvmTypes.Pubkey.toString, o.byteLengthsDesc))
      ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
    t.expect(byProgram).toEqual([
      ("11111111111111111111111111111111", [0]),
      ("metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s", [8, 1]),
    ])
  })
})
