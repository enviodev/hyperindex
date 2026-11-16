// Turns the rows an `EventStore` hands out back into the items handlers
// receive, with each source's own item conversion.

// What rebuilding an item from its row needs: the chain's registrations, by
// the index rows carry.
type context = {
  chainId: ChainId.t,
  onEventRegistrations: array<Internal.onEventRegistration>,
  onBlockRegistrations: array<Internal.onBlockRegistration>,
}

let toItem = (rows: EventStore.storedRows, index, ~context: context): Internal.item => {
  let data = rows.data->Array.getUnsafe(index)
  switch rows->EventStore.formatAt(index) {
  | EvmLog =>
    let item = data->(Utils.magic: unknown => EvmEventItem.t)
    item->EvmEventItem.toInternalItem(
      ~onEventRegistration=context.onEventRegistrations
      ->Array.getUnsafe(item.onEventRegistrationIndex)
      ->(Utils.magic: Internal.onEventRegistration => Internal.evmOnEventRegistration),
      ~chainId=context.chainId,
    )
  | FuelReceipt =>
    let item = data->(Utils.magic: unknown => FuelHyperSyncClient.EventItems.item)
    item->FuelEventItem.toInternalItem(
      ~onEventRegistration=context.onEventRegistrations->Array.getUnsafe(
        item.onEventRegistrationIndex,
      ),
      ~chainId=context.chainId,
    )
  | SvmInstruction =>
    let item = data->(Utils.magic: unknown => SvmHyperSyncClient.Items.item)
    item->SvmEventItem.toInternalItem(
      ~onEventRegistration=context.onEventRegistrations->Array.getUnsafe(
        item.onEventRegistrationIndex,
      ),
      ~chainId=context.chainId,
    )
  | Block =>
    data
    ->(Utils.magic: unknown => BlockItem.t)
    ->BlockItem.toInternalItem(~onBlockRegistrations=context.onBlockRegistrations)
  | JsItem =>
    let item = data->(Utils.magic: unknown => dict<unknown>)
    let registrationIndex = rows->EventStore.registrationIndexAt(index)
    switch item->Dict.getUnsafe("kind")->(Utils.magic: unknown => int) {
    | 0 =>
      item->Dict.set(
        "onEventRegistration",
        context.onEventRegistrations
        ->Array.getUnsafe(registrationIndex)
        ->(Utils.magic: Internal.onEventRegistration => unknown),
      )
    | _ =>
      item->Dict.set(
        "onBlockRegistration",
        context.onBlockRegistrations
        ->Array.getUnsafe(registrationIndex)
        ->(Utils.magic: Internal.onBlockRegistration => unknown),
      )
    }
    item->(Utils.magic: dict<unknown> => Internal.item)
  }
}

let toItems = (rows: EventStore.storedRows, ~context: context): array<Internal.item> =>
  rows.data->Array.mapWithIndex((_, index) => rows->toItem(index, ~context))

// Removes the first `count` items from the store and returns them.
let take = (store: EventStore.t, count: int, ~context: context): array<Internal.item> =>
  store->EventStore.takeRaw(count)->toItems(~context)

// Every item in the store, which keeps them.
let allItems = (store: EventStore.t, ~context: context): array<Internal.item> =>
  store->EventStore.allItemsRaw->toItems(~context)

// The events routed to the given registrations, which the store keeps.
let eventsOfRegistrations = (
  store: EventStore.t,
  registrationIndexes: array<int>,
  ~context: context,
): array<Internal.item> =>
  store->EventStore.eventsOfRegistrationsRaw(registrationIndexes)->toItems(~context)
