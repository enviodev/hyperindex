open Vitest

// Live test: hit `solana.hypersync.xyz` and verify that the napi binding +
// ReScript wrapper return Metaplex Token Metadata instructions for the most
// recent slot window.
//
// `describe_skip` so CI / `pnpm test` doesn't depend on the network. Flip to
// `describe` to run locally.
describe_skip("SvmHyperSyncClient live", () => {
  let tokenMetadataProgram = "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s"

  Async.it("returns Token Metadata instructions for a recent slot window", async t => {
    let client = SvmHyperSyncClient.make(~url="https://solana.hypersync.xyz")
    let height = await client.getHeight()
    let query: SvmHyperSyncClient.query = {
      fromSlot: Pervasives.max(0, height - 10_000),
      toSlot: height,
      instructions: [{programId: [tokenMetadataProgram]}],
      maxNumInstructions: 200,
      // Default merge mode: requesting a table's columns opts the matched
      // result set into that join — no per-selection include flags needed.
      fields: {
        block: [Slot, Blockhash, BlockTime],
        transaction: [Slot, TransactionIndex, Signatures],
      },
    }
    // The store page is exercised by SvmHyperSyncSource; here we assert the
    // response shape only.
    let (resp, _, _) = await client.get(~query)
    // Option-typed so an empty live response fails the shape assertion below
    // instead of throwing on the index.
    let first = resp.data.instructions->Array.get(0)

    let blockTimeBySlot = Dict.make()
    resp.data.blocks->Array.forEach(b =>
      switch b.blockTime {
      | Some(time) => blockTimeBySlot->Dict.set(b.slot->Int.toString, time)
      | None => ()
      }
    )

    let summary = {
      "heightLooksRecent": height > 300_000_000,
      "hasInstructions": resp.data.instructions->Array.length > 0,
      "firstProgramId": first->Option.mapOr("", i => i.programId),
      "firstDataIsHex": first->Option.mapOr(false, i => i.data->String.startsWith("0x")),
      // Every matched instruction's slot must come with a sane blockTime —
      // `SvmHyperSyncSource` relies on this join for `instruction.block.time`.
      "allInstructionSlotsHaveBlockTime": resp.data.instructions->Array.every(instr =>
        switch blockTimeBySlot->Dict.get(instr.slot->Int.toString) {
        | Some(time) => time > 1_600_000_000
        | None => false
        }
      ),
    }
    t.expect(summary).toEqual({
      "heightLooksRecent": true,
      "hasInstructions": true,
      "firstProgramId": tokenMetadataProgram,
      "firstDataIsHex": true,
      "allInstructionSlotsHaveBlockTime": true,
    })
  })
})
