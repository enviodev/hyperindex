open Vitest

// Live test: hit `solana.hypersync.xyz` and verify that the napi binding +
// ReScript wrapper return Metaplex Token Metadata instructions for the most
// recent slot window.
//
// `describe_skip` so CI / `pnpm test` doesn't depend on the network. Flip to
// `describe` to run locally.
describe_skip("HyperSyncSolanaClient live", () => {
  let tokenMetadataProgram = "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s"

  Async.it("returns Token Metadata instructions for a recent slot window", async t => {
    let client = HyperSyncSolanaClient.make(~url="https://solana.hypersync.xyz")
    let height = await client.getHeight()
    let query: HyperSyncSolanaClient.query = {
      fromSlot: Pervasives.max(0, height - 10_000),
      toSlot: height,
      instructions: [{programId: [tokenMetadataProgram], includeTransaction: true}],
      maxNumInstructions: 200,
    }
    let resp = await client.get(~query)
    let first = resp.data.instructions->Array.getUnsafe(0)

    let summary = {
      "heightLooksRecent": height > 300_000_000,
      "hasInstructions": resp.data.instructions->Array.length > 0,
      "firstProgramId": first.programId,
      "firstDataIsHex": first.data->String.startsWith("0x"),
    }
    t.expect(summary).toEqual({
      "heightLooksRecent": true,
      "hasInstructions": true,
      "firstProgramId": tokenMetadataProgram,
      "firstDataIsHex": true,
    })
  })
})
