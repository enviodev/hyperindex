type t

type cfg = {
  url: string,
  apiToken: string,
}

module Registration = {
  type kind =
    | @as("LogData") LogData
    | @as("Mint") Mint
    | @as("Burn") Burn
    | @as("Transfer") Transfer
    | @as("Call") Call

  // The full per-(event, chain) registration passed to the Rust client at
  // construction: routing identity plus the receipt-selection state queries
  // are built from.
  type input = {
    // Chain-scoped sequential registration index, echoed back on routed items.
    index: int,
    eventName: string,
    contractName: string,
    isWildcard: bool,
    kind: kind,
    // The LogData `rb` value as a decimal string; absent for other kinds.
    logId?: string,
  }

  let fromOnEventRegistrations = (
    onEventRegistrations: array<Internal.fuelOnEventRegistration>,
  ): array<input> =>
    onEventRegistrations->Array.map(reg => {
      let eventConfig =
        reg.eventConfig->(Utils.magic: Internal.eventConfig => Internal.fuelEventConfig)
      let (kind, logId) = switch eventConfig.kind {
      | LogData({logId}) => (LogData, Some(logId))
      | Mint => (Mint, None)
      | Burn => (Burn, None)
      | Transfer => (Transfer, None)
      | Call => (Call, None)
      }
      {
        index: reg.index,
        eventName: eventConfig.name,
        contractName: eventConfig.contractName,
        isWildcard: reg.isWildcard,
        kind,
        ?logId,
      }
    })
}

module EventItems = {
  // The whole per-query input: block range, the partition's registration
  // selection (by index), and its current addresses. Receipt selections,
  // field selection, and routing are derived on the Rust side.
  type query = {
    fromBlock: int,
    // Inclusive; None queries to the end of available data.
    toBlock: option<int>,
    registrationIndexes: array<int>,
    addressesByContractName: dict<array<Address.t>>,
  }

  // One routed receipt with its kind-specific columns flattened: LogData
  // carries `data` (decoded here in JS), Mint/Burn carry `val`/`subId`,
  // Transfer/TransferOut/Call carry `amount`/`assetId`/`to` (TransferOut's
  // wallet recipient normalised into `to`).
  type item = {
    onEventRegistrationIndex: int,
    receiptIndex: int,
    txId: string,
    blockHeight: int,
    srcAddress: Address.t,
    data?: string,
    subId?: string,
    val?: bigint,
    amount?: bigint,
    assetId?: string,
    to?: string,
  }

  type block = {
    id: string,
    height: int,
    time: int,
  }

  type response = {
    archiveHeight: option<int>,
    nextBlock: int,
    // One block per height; items reference them by `blockHeight`.
    blocks: array<block>,
    items: array<item>,
  }
}

@send
external classNew: (
  Core.hyperfuelClientCtor,
  cfg,
  ~userAgent: string,
  array<Registration.input>,
) => t = "new"

let make = (cfg: cfg, ~eventRegistrations) => {
  let envioVersion = Utils.EnvioPackage.value.version
  Core.getAddon().hyperfuelClient->classNew(
    cfg,
    ~userAgent=`hyperindex/${envioVersion}`,
    eventRegistrations,
  )
}

@send
external getEventItems: (t, EventItems.query) => promise<EventItems.response> = "getEventItems"

@send
external getHeight: t => promise<int> = "getHeight"
