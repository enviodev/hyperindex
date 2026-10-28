// A transaction a source routed to a handler; its fields and its block's are
// materialised at batch prep from the response's stores.
type t = {
  blockNumber: int,
  transactionIndex: int,
  onTransactionRegistrationIndex: int,
}

type registrationInput = {
  index: int,
  from: array<string>,
  to: array<string>,
  sighash: array<string>,
  status: option<int>,
  // Capitalized, as the Rust field enums spell them.
  transactionFields: array<string>,
  blockFields: array<string>,
}

let toRegistrationInputs = (
  onTransactionRegistrations: array<Internal.onTransactionRegistration>,
) =>
  onTransactionRegistrations->Array.map(({index, from, to, sighash, status, fieldSelection}) => {
    index,
    from: from->(Utils.magic: array<Address.t> => array<string>),
    to: to->(Utils.magic: array<Address.t> => array<string>),
    sighash,
    status,
    transactionFields: fieldSelection.transactionFields
    ->Utils.Set.toArray
    ->Array.map(Utils.String.capitalize),
    blockFields: fieldSelection.blockFields->Utils.Set.toArray->Array.map(Utils.String.capitalize),
  })

// Mirrors `Registration::matches` in `transaction_selection.rs`, for the
// sources that build their items in ReScript (simulate, mocks).
let matches = (
  {from, to, sighash, status}: Internal.onTransactionRegistration,
  ~transaction: Internal.eventTransaction,
) => {
  let fields = transaction->(Utils.magic: Internal.eventTransaction => dict<unknown>)
  let text = key =>
    switch fields->Dict.get(key) {
    | Some(value) if typeof(value) === #string =>
      Some(value->(Utils.magic: unknown => string)->String.toLowerCase)
    | _ => None
    }
  let anyOf = (accepted: array<string>, actual) =>
    accepted->Utils.Array.isEmpty ||
      actual->Option.mapOr(false, actual => accepted->Array.includes(actual))
  let addresses = values => values->(Utils.magic: array<Address.t> => array<string>)
  anyOf(from->addresses, text("from")) &&
  anyOf(to->addresses, text("to")) &&
  anyOf(sighash, text("input")->Option.map(input => input->String.slice(~start=0, ~end=10))) &&
  status->Option.mapOr(true, wanted =>
    fields->Dict.get("status")->(Utils.magic: option<unknown> => option<int>) === Some(wanted)
  )
}

let toInternalItems = (
  items: array<t>,
  ~onTransactionRegistrations: array<Internal.onTransactionRegistration>,
  ~chainId,
): array<Internal.item> =>
  items->Array.map(({
    blockNumber,
    transactionIndex,
    onTransactionRegistrationIndex,
  }) => Internal.Transaction({
    onTransactionRegistration: onTransactionRegistrations->Array.getUnsafe(
      onTransactionRegistrationIndex,
    ),
    chainId,
    blockNumber,
    transactionIndex,
  }))
