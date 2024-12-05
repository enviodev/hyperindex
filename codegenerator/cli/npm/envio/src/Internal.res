type eventParams
type eventBlock
type eventTransaction

@genType
type genericEvent<'params, 'transaction, 'block> = {
  params: 'params,
  chainId: int,
  srcAddress: Address.t,
  logIndex: int,
  transaction: 'transaction,
  block: 'block,
}

type event = genericEvent<eventParams, eventTransaction, eventBlock>

external fromGenericEvent: genericEvent<'a, 'b, 'c> => event = "%identity"
external toGenericEvent: event => genericEvent<'a, 'b, 'c> = "%identity"

type loaderReturn
