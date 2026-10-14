open Vitest

// A response is applied only once every register pass of it is done, and a
// subgraph's pass can cost a dozen contract calls: PancakeSwap v2's first
// response held 5,000 PairCreated events and committed nothing for ~15,000
// calls. A response with more register passes than the runtime can answer
// promptly is cut after a block, and the rest is fetched again.
describe("cutting a response at its register limit", () => {
  let item = (~block, ~registers): Internal.item =>
    {
      "kind": 0,
      "blockNumber": block,
      "onEventRegistration": {"contractRegister": registers ? Some(() => Promise.resolve()) : None},
    }->(Utils.magic: {..} => Internal.item)

  let blocks = (items: array<Internal.item>) => items->Array.map(Internal.getItemBlockNumber)

  it("keeps whole blocks: the cut item's block stays complete", t => {
    let items = [
      item(~block=1, ~registers=true),
      item(~block=2, ~registers=true),
      item(~block=2, ~registers=false),
      item(~block=2, ~registers=true),
      item(~block=3, ~registers=true),
    ]
    let (kept, latest) = items->ChainFetching.cutAtRegisterLimit(~latestFetchedBlock=10, ~limit=2)
    t.expect((blocks(kept), latest)).toEqual(([1, 2, 2, 2], 2))
  })

  it("leaves a response within the limit as it is", t => {
    let items = [item(~block=1, ~registers=true), item(~block=2, ~registers=false)]
    let (kept, latest) = items->ChainFetching.cutAtRegisterLimit(~latestFetchedBlock=10, ~limit=5)
    t.expect((blocks(kept), latest)).toEqual(([1, 2], 10))
  })

  it("does not cut when the limit lands in the response's last block", t => {
    let items = [item(~block=1, ~registers=true), item(~block=9, ~registers=true)]
    let (kept, latest) = items->ChainFetching.cutAtRegisterLimit(~latestFetchedBlock=9, ~limit=2)
    t.expect((blocks(kept), latest)).toEqual(([1, 9], 9))
  })

  it("counts only the items that have a register pass", t => {
    let items = Array.concat(
      Array.make(~length=50, item(~block=1, ~registers=false)),
      [item(~block=2, ~registers=true), item(~block=3, ~registers=true), item(~block=4, ~registers=true)],
    )
    let (kept, latest) = items->ChainFetching.cutAtRegisterLimit(~latestFetchedBlock=100, ~limit=2)
    t.expect((kept->Array.length, latest)).toEqual((52, 3))
  })

  it("sizes the limit by what the finished passes cost", t => {
    let before = Env.subgraphMode.contents
    Env.subgraphMode := true
    let setCost: option<float> => unit = %raw(`(cost) => {
      globalThis.__envioSubgraphRegisterCostPerItem = () => cost
    }`)
    setCost(None)
    let unknown = ChainFetching.registerChunkLimit()
    setCost(Some(0.))
    let free = ChainFetching.registerChunkLimit()
    setCost(Some(10.))
    let dozen = ChainFetching.registerChunkLimit()
    setCost(Some(1000.))
    let huge = ChainFetching.registerChunkLimit()
    Env.subgraphMode := false
    let handlerRun = ChainFetching.registerChunkLimit()
    Env.subgraphMode := before
    t.expect((unknown, free, dozen, huge, handlerRun)).toEqual((Some(100), None, Some(300), Some(100), None))
  })
})
