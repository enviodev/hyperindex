open RescriptMocha
open Belt

describe("Test Processing Filters", () => {
  // Assert.deepEqual doesn't work, because of deeply nested rescript-schema objects
  // Assert.equal doesn't work because the array is always recreated on filter
  // So I added the helper
  let assertEqualItems = (items1, items2) => {
    Assert.equal(
      items1->Array.length,
      items2->Array.length,
      ~message="Length of the items doesn't match",
    )
    items1->Array.forEachWithIndex((i, item1) => {
      let item2 = items2->Js.Array2.unsafe_get(i)
      Assert.equal(item1, item2)
    })
  }

  it("Keeps items when there are not filters", () => {
    let items = MockEvents.eventBatchItems
    assertEqualItems(
      items,
      items->Js.Array2.filter(
        item => ChainFetcher.applyProcessingFilters(~item, ~processingFilters=[]),
      ),
    )
  })

  it("Keeps items when all filters return true", () => {
    let items = MockEvents.eventBatchItems
    assertEqualItems(
      items,
      items->Js.Array2.filter(
        item =>
          ChainFetcher.applyProcessingFilters(
            ~item,
            ~processingFilters=[
              {
                filter: _ => true,
                isValid: (~fetchState as _) => true,
              },
              {
                filter: _ => true,
                isValid: (~fetchState as _) => true,
              },
            ],
          ),
      ),
    )
  })

  it("Removes all items when there is one filter returning false", () => {
    let items = MockEvents.eventBatchItems
    assertEqualItems(
      [],
      items->Js.Array2.filter(
        item =>
          ChainFetcher.applyProcessingFilters(
            ~item,
            ~processingFilters=[
              {
                filter: _ => false,
                isValid: (~fetchState as _) => true,
              },
              {
                filter: _ => true,
                isValid: (~fetchState as _) => true,
              },
            ],
          ),
      ),
    )
  })
})
