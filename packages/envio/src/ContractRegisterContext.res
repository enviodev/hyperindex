// The contractRegister handler context: context.chain.ContractName.add(address).
// Independent of the in-memory store, so it stays off IndexerState and the
// fetch-time contract registration in ChainFetcher doesn't pull the state in.

type contractRegisterParams = {
  item: Internal.item,
  onRegister: (~item: Internal.item, ~contractAddress: Address.t, ~contractName: string) => unit,
  config: Config.t,
  mutable isResolved: bool,
}

// Helper to create a validated add function for contract registration.
// The isResolved check has to live inside the returned closure (not just in the
// outer proxy trap) because users can capture `const add = context.chain.X.add`
// before awaiting — a later call would otherwise bypass the resolved guard.
let makeAddFunction = (~params: contractRegisterParams, ~contractName: string): (
  Address.t => unit
) => {
  (contractAddress: Address.t) => {
    if params.isResolved {
      Utils.Error.make(`Impossible to access context.chain after the contract register is resolved. Make sure you didn't miss an await in the handler.`)->ErrorHandling.mkLogAndRaise(
        ~logger=params.item->Logging.getItemLogger,
      )
    }
    let validatedAddress = if params.config.ecosystem.name === Evm {
      // The value is passed from the user-land,
      // so we need to validate and checksum/lowercase the address.
      if params.config.lowercaseAddresses {
        contractAddress->Address.Evm.fromAddressLowercaseOrThrow
      } else {
        contractAddress->Address.Evm.fromAddressOrThrow
      }
    } else {
      // TODO: Ideally we should do the same for other ecosystems
      contractAddress
    }

    params.onRegister(~item=params.item, ~contractAddress=validatedAddress, ~contractName)
  }
}

// Chain proxy for contractRegister context: context.chain.ContractName.add(address)
let contractRegisterChainTraps: Utils.Proxy.traps<contractRegisterParams> = {
  get: (~target as params, ~prop: unknown) => {
    let prop = prop->(Utils.magic: unknown => string)
    switch prop {
    | "id" =>
      let eventItem = params.item->Internal.castUnsafeEventItem
      eventItem.chain->ChainMap.Chain.toChainId->(Utils.magic: int => unknown)
    | _ =>
      // Look up the contract name directly in config contracts across all chains.
      let contractName = prop
      let isValidContract =
        params.config.chainMap
        ->ChainMap.values
        ->Array.some(chain => chain.contracts->Array.some(c => c.name === contractName))
      if isValidContract {
        let addFn = makeAddFunction(~params, ~contractName)
        {"add": addFn}->(Utils.magic: {"add": Address.t => unit} => unknown)
      } else {
        JsError.throwWithMessage(
          `Invalid contract name '${prop}' on context.chain. ${EntityFilter.codegenHelpMessage}`,
        )
      }
    }
  },
}

let contractRegisterTraps: Utils.Proxy.traps<contractRegisterParams> = {
  get: (~target as params, ~prop: unknown) => {
    let prop = prop->(Utils.magic: unknown => string)
    if params.isResolved {
      Utils.Error.make(
        `Impossible to access context.${prop} after the contract register is resolved. Make sure you didn't miss an await in the handler.`,
      )->ErrorHandling.mkLogAndRaise(~logger=params.item->Logging.getItemLogger)
    }
    switch prop {
    | "log" => params.item->Logging.getUserLogger->(Utils.magic: Envio.logger => unknown)
    | "chain" =>
      params
      ->Utils.Proxy.make(contractRegisterChainTraps)
      ->(Utils.magic: contractRegisterParams => unknown)
    | _ =>
      JsError.throwWithMessage(
        `Invalid context access by '${prop}' property. Use context.chain.ContractName.add(address) to register contracts. ${EntityFilter.codegenHelpMessage}`,
      )
    }
  },
}

let getContractRegisterContext = (params: contractRegisterParams) => {
  params
  ->Utils.Proxy.make(contractRegisterTraps)
  ->(Utils.magic: contractRegisterParams => Internal.contractRegisterContext)
}

let getContractRegisterArgs = (params: contractRegisterParams): Internal.contractRegisterArgs => {
  event: (params.item->Internal.castUnsafeEventItem).event,
  context: getContractRegisterContext(params),
}
