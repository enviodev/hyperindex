// Every item a store holds, which it keeps. A row built in JS gets back a
// registration carrying only its index, which is all the fetch state tests'
// mock items have; any other row is rebuilt with `context`'s registrations.
let itemsOf = (store: EventStore.t, ~context: StoredItems.context): array<Internal.item> =>
  store
  ->EventStore.allItemsRaw
  ->Array.map(stored =>
    switch stored.format {
    | JsItem =>
      let data = stored.data->(Utils.magic: unknown => dict<unknown>)
      let registration =
        {"index": stored.registrationIndex}->(Utils.magic: {"index": int} => unknown)
      switch data->Dict.getUnsafe("kind")->(Utils.magic: unknown => int) {
      | 0 => data->Dict.set("onEventRegistration", registration)
      | _ => data->Dict.set("onBlockRegistration", registration)
      }
      data->(Utils.magic: dict<unknown> => Internal.item)
    | _ => stored->StoredItems.toItem(~context)
    }
  )

let bufferedItems = (fetchState: FetchState.t): array<Internal.item> =>
  fetchState.eventStore->itemsOf(~context=fetchState.itemContext)

let pageOf = (items: array<Internal.item>) => EventStore.fromJsItems(items)

// Puts `items` in the fetch state's store, as an applied response would.
let withItems = (fetchState: FetchState.t, items: array<Internal.item>) => {
  fetchState.eventStore->EventStore.merge(pageOf(items))
  fetchState
}

// The EVM logs a source page holds, as the source routed them.
let evmLogsOf = (page: EventStore.t): array<EvmEventItem.t> =>
  page
  ->EventStore.allItemsRaw
  ->Array.map(stored => stored.data->(Utils.magic: unknown => EvmEventItem.t))

// For a fetch state built by hand, whose rows are all built in JS.
let noRegistrations = (~chainId): StoredItems.context => {
  chainId,
  onEventRegistrations: [],
  onBlockRegistrations: [],
}
