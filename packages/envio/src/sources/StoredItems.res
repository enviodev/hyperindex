// Turns the rows an `EventStore` hands out back into the items handlers
// receive, with each source's own item conversion.

// What rebuilding an item from its row needs: the chain's registrations, by
// the index rows carry.
type context = {
  chainId: ChainId.t,
  onEventRegistrations: array<Internal.onEventRegistration>,
  onBlockRegistrations: array<Internal.onBlockRegistration>,
}

let toItem = (stored: EventStore.storedItem, ~context: context): Internal.item =>
  switch stored.format {
  | EvmLog =>
    let item = stored.data->(Utils.magic: unknown => EvmEventItem.t)
    item->EvmEventItem.toInternalItem(
      ~onEventRegistration=context.onEventRegistrations
      ->Array.getUnsafe(item.onEventRegistrationIndex)
      ->(Utils.magic: Internal.onEventRegistration => Internal.evmOnEventRegistration),
      ~chainId=context.chainId,
    )
  | FuelReceipt =>
    let item = stored.data->(Utils.magic: unknown => FuelHyperSyncClient.EventItems.item)
    item->FuelEventItem.toInternalItem(
      ~onEventRegistration=context.onEventRegistrations->Array.getUnsafe(
        item.onEventRegistrationIndex,
      ),
      ~chainId=context.chainId,
    )
  | SvmInstruction =>
    let item = stored.data->(Utils.magic: unknown => SvmHyperSyncClient.Items.item)
    item->SvmEventItem.toInternalItem(
      ~onEventRegistration=context.onEventRegistrations->Array.getUnsafe(
        item.onEventRegistrationIndex,
      ),
      ~chainId=context.chainId,
    )
  | Block =>
    stored.data
    ->(Utils.magic: unknown => BlockItem.t)
    ->BlockItem.toInternalItem(~onBlockRegistrations=context.onBlockRegistrations)
  | JsItem =>
    let data = stored.data->(Utils.magic: unknown => dict<unknown>)
    switch data->Dict.getUnsafe("kind")->(Utils.magic: unknown => int) {
    | 0 =>
      data->Dict.set(
        "onEventRegistration",
        context.onEventRegistrations
        ->Array.getUnsafe(stored.registrationIndex)
        ->(Utils.magic: Internal.onEventRegistration => unknown),
      )
    | _ =>
      data->Dict.set(
        "onBlockRegistration",
        context.onBlockRegistrations
        ->Array.getUnsafe(stored.registrationIndex)
        ->(Utils.magic: Internal.onBlockRegistration => unknown),
      )
    }
    data->(Utils.magic: dict<unknown> => Internal.item)
  }

// Removes the first `count` items from the store and returns them.
let take = (store: EventStore.t, count: int, ~context: context): array<Internal.item> =>
  store->EventStore.takeRaw(count)->Array.map(stored => stored->toItem(~context))

// Every item in the store, which keeps them.
let allItems = (store: EventStore.t, ~context: context): array<Internal.item> =>
  store->EventStore.allItemsRaw->Array.map(stored => stored->toItem(~context))

// The events routed to the given registrations, which the store keeps.
let eventsOfRegistrations = (
  store: EventStore.t,
  registrationIndexes: array<int>,
  ~context: context,
): array<Internal.item> =>
  store
  ->EventStore.eventsOfRegistrationsRaw(registrationIndexes)
  ->Array.map(stored => stored->toItem(~context))
