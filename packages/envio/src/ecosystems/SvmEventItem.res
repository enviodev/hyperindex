// An instruction as the chain buffer delivers it.
type log = {
  kind: Nullable.t<string>,
  message: Nullable.t<string>,
}

type item = {
  slot: int,
  transactionIndex: int,
  path: array<int>,
  programId: string,
  accounts: array<string>,
  data: Uint8Array.t,
  isInner: bool,
  args: Nullable.t<unknown>,
  logs: Nullable.t<array<log>>,
}

%%private(
  let namedAccounts = (
    ~slots: array<Internal.svmAccountSlot>,
    ~accountArguments: array<string>,
    ~programId: string,
  ): dict<Envio.svmInstructionAccount> => {
    let out = Dict.make()
    slots->Array.forEachWithIndex((slot, i) =>
      switch (slot, accountArguments->Array.get(i)) {
      | (Unnamed, _) | (_, None) => ()
      | (Optional(_), Some(address)) if address === programId => ()
      | (Required(name), Some(address)) | (Optional(name), Some(address)) =>
        out->Dict.set(
          name,
          {
            Envio.address: address->SvmTypes.Pubkey.fromStringUnsafe,
            accountName: name,
            instructionAccountIndex: i,
          },
        )
      }
    )
    out
  }

  let selectedLog = (log: log, ~logFields: Utils.Set.t<string>): Envio.svmLog => {
    let out = Dict.make()
    if logFields->Utils.Set.has("kind") {
      switch log.kind->Nullable.toOption {
      | Some(kind) => out->Dict.set("kind", kind)
      | None => ()
      }
    }
    if logFields->Utils.Set.has("message") {
      switch log.message->Nullable.toOption {
      | Some(message) => out->Dict.set("message", message)
      | None => ()
      }
    }
    out->(Utils.magic: dict<string> => Envio.svmLog)
  }

  let setField = (out: dict<unknown>, name: string, value: 'a) =>
    out->Dict.set(name, value->(Utils.magic: 'a => unknown))
)

// `block` and `transaction` are omitted; the build joins them onto the item.
// Named-account `.activity` is attached then too.
// Unselected instruction keys must be omitted, not assigned `undefined`.
let toSvmInstruction = (
  item: item,
  ~programName,
  ~instructionName,
  ~eventConfig: Internal.svmInstructionEventConfig,
  ~fieldSelection: Internal.fieldSelection,
): Envio.svmInstruction => {
  let hasSelection = name => fieldSelection.instructionFields->Utils.Set.has(name)
  // A program-wide registration has no configured discriminator, so the whole
  // data stands in, hex-encoded like a configured one would be.
  let discriminator = switch eventConfig.discriminator {
  | Some(d) => d
  | None => "0x" ++ item.data->NodeJs.Buffer.fromUint8Array->NodeJs.Buffer.toHex
  }
  let out = Dict.make()
  out->setField("programName", programName)
  out->setField("instructionName", instructionName)
  out->setField("discriminator", discriminator)
  if hasSelection("programId") {
    out->setField("programId", item.programId->SvmTypes.Pubkey.fromStringUnsafe)
  }
  if hasSelection("data") {
    out->setField("data", item.data)
  }
  if hasSelection("path") {
    out->setField("path", item.path)
  }
  if hasSelection("isInner") {
    out->setField("isInner", item.isInner)
  }
  switch item.args->Nullable.toOption {
  | Some(args) => out->setField("args", args)
  | None => ()
  }
  if hasSelection("accounts") {
    out->setField(
      "accounts",
      namedAccounts(
        ~slots=eventConfig.accounts,
        ~accountArguments=item.accounts,
        ~programId=item.programId,
      ),
    )
  }
  if hasSelection("accountArguments") {
    out->setField("accountArguments", item.accounts->SvmTypes.Pubkey.fromStringsUnsafe)
  }
  if fieldSelection.logFields->Utils.Set.size > 0 {
    out->setField(
      "logs",
      item.logs
      ->Nullable.getOr([])
      ->Array.map(log => selectedLog(log, ~logFields=fieldSelection.logFields)),
    )
  }
  out->(Utils.magic: dict<unknown> => Envio.svmInstruction)
}

let toInternalItem = (
  item: item,
  ~onEventRegistration: Internal.onEventRegistration,
  ~chainId,
): Internal.item => {
  let eventConfig =
    onEventRegistration.eventConfig->(
      Utils.magic: Internal.eventConfig => Internal.svmInstructionEventConfig
    )
  let payload = toSvmInstruction(
    item,
    ~programName=eventConfig.contractName,
    ~instructionName=eventConfig.name,
    ~eventConfig,
    ~fieldSelection=onEventRegistration.fieldSelection,
  )
  Internal.Event({
    onEventRegistration,
    chainId,
    blockNumber: item.slot,
    // A slot orders by `(transactionIndex, path)` — the
    // transaction, then the instruction's position in its CPI tree. Both
    // ride the item so the buffer comparator can order on the pair
    // directly; no single integer can hold it (Solana allows a CPI depth
    // of 5, which needs more bits than a JS integer is exact to).
    logIndex: item.transactionIndex,
    orderPath: item.path,
    // The parent transaction is materialised from the store at batch prep.
    transactionIndex: item.transactionIndex,
    payload: payload->(Utils.magic: Envio.svmInstruction => Internal.eventPayload),
  })
}
