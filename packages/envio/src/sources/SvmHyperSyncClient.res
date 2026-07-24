type cfg = {
  /** HyperSync server URL. */
  url: string,
  /** Optional bearer token for the HyperSync server. */
  apiToken?: string,
  httpReqTimeoutMillis?: int,
  maxNumRetries?: int,
  retryBaseMs?: int,
  retryCeilingMs?: int,
}

module Registration = {
  type accountFilter = {
    position: int,
    values: array<string>,
  }

  // The full per-(instruction, chain) registration passed to the Rust client
  // at construction: routing identity, the fetch state queries are built
  // from, and the Borsh schema pieces the client builds decoders from.
  type input = {
    // Chain-scoped sequential registration index, echoed back on routed items.
    index: int,
    instructionName: string,
    contractName: string,
    programId: string,
    isWildcard: bool,
    discriminator?: string,
    discriminatorByteLen: int,
    isInner?: bool,
    includeLogs: bool,
    // DNF: outer array is OR of AND-groups.
    accountFilters: array<array<accountFilter>>,
    // camelCase Internal.svmTransactionField / svmBlockField names.
    transactionFields: array<string>,
    blockFields: array<string>,
    // Borsh schema pieces; empty accounts + absent argsJson = no schema.
    accounts: array<string>,
    argsJson?: string,
    definedTypesJson?: string,
  }

  let fromOnEventRegistrations = (
    onEventRegistrations: array<Internal.svmOnEventRegistration>,
  ): array<input> =>
    onEventRegistrations->Array.map(reg => {
      let eventConfig =
        reg.eventConfig->(Utils.magic: Internal.eventConfig => Internal.svmInstructionEventConfig)
      {
        index: reg.index,
        instructionName: eventConfig.name,
        contractName: eventConfig.contractName,
        programId: eventConfig.programId->SvmTypes.Pubkey.toString,
        isWildcard: reg.isWildcard,
        discriminator: ?eventConfig.discriminator,
        discriminatorByteLen: eventConfig.discriminatorByteLen,
        isInner: ?eventConfig.isInner,
        includeLogs: eventConfig.includeLogs,
        accountFilters: eventConfig.accountFilters->Array.map(group =>
          group->Array.map(
            (filter): accountFilter => {
              position: filter.position,
              values: filter.values->SvmTypes.Pubkey.toStrings,
            },
          )
        ),
        transactionFields: eventConfig.selectedTransactionFields->Utils.Set.toArray,
        blockFields: eventConfig.selectedBlockFields
        ->(Utils.magic: Utils.Set.t<Internal.svmBlockField> => Utils.Set.t<string>)
        ->Utils.Set.toArray,
        accounts: eventConfig.accounts,
        argsJson: ?switch eventConfig.args {
        | JSON.Null => None
        | args => Some(args->JSON.stringify)
        },
        definedTypesJson: ?switch eventConfig.definedTypes {
        | JSON.Null => None
        | definedTypes => Some(definedTypes->JSON.stringify)
        },
      }
    })
}

module QueryTypes = {
  type blockField =
    | @as("slot") Slot
    | @as("blockhash") Blockhash
    | @as("parent_slot") ParentSlot
    | @as("parent_blockhash") ParentBlockhash
    | @as("block_time") BlockTime
    | @as("block_height") BlockHeight

  type transactionField =
    | @as("slot") Slot
    | @as("transaction_index") TransactionIndex
    | @as("signatures") Signatures
    | @as("fee_payer") FeePayer
    | @as("success") Success
    | @as("err") Err
    | @as("fee") Fee
    | @as("compute_units_consumed") ComputeUnitsConsumed
    | @as("account_keys") AccountKeys
    | @as("recent_blockhash") RecentBlockhash
    | @as("version") Version
    | @as("loaded_addresses_writable") LoadedAddressesWritable
    | @as("loaded_addresses_readonly") LoadedAddressesReadonly

  type fieldSelection = {block?: array<blockField>, transaction?: array<transactionField>}

  /** Filter for selecting instructions. All non-empty fields are AND-ed: an
   instruction must match at least one value in every non-empty field.

   Discriminator filters (d1..d8) take hex-encoded byte prefixes ("0x" optional).
   Account filters (a0..a9) take base58 pubkey strings. */
  type instructionSelection = {
    programId?: array<string>,
    d1?: array<string>,
    d2?: array<string>,
    d4?: array<string>,
    d8?: array<string>,
    isInner?: bool,
  }

  // The `get` query surface, used only for block-data range queries; event
  // fetching goes through `getEventItems`, which builds its query in Rust.
  type query = {
    fromSlot: int,
    toSlot?: int,
    instructions?: array<instructionSelection>,
    includeAllBlocks?: bool,
    fields?: fieldSelection,
    maxNumBlocks?: int,
    maxNumInstructions?: int,
  }
}

module ResponseTypes = {
  // Lean per-slot header for reorg detection and each item's slot/time; the
  // selectable fields live in the block store and are materialised on demand.
  type block = {
    slot: int,
    blockhash: string,
    blockTime?: int,
  }

  /// Borsh-decoded view attached by the Rust client. `argsJson`/`accountsJson`
  /// are stringified to side-step napi-rs's lack of native JSON passthrough.
  type decodedInstruction = {
    name: string,
    argsJson: string,
    accountsJson: string,
    extraAccounts: array<string>,
  }

  type instruction = {
    slot: int,
    transactionIndex: int,
    instructionAddress: array<int>,
    programId: string,
    accounts: array<string>,
    data: string,
    d1?: string,
    d2?: string,
    d4?: string,
    d8?: string,
    isInner: bool,
    isCommitted: bool,
  }

  type queryResponseData = {
    blocks: array<block>,
    instructions: array<instruction>,
  }

  type queryResponse = {
    nextSlot: int,
    responseBytes: int,
    data: queryResponseData,
  }
}

module EventItems = {
  // The whole per-query input: slot range, the partition's registration
  // selection (by index), and its current addresses (program ids per program
  // name). Instruction selections, field selection, and routing are derived
  // on the Rust side.
  type query = {
    fromSlot: int,
    // Inclusive; None queries to the end of available data.
    toSlot: option<int>,
    // Absent means no server-side cap on the number of instructions returned.
    maxNumInstructions?: int,
    registrationIndexes: array<int>,
    addressesByContractName: dict<array<Address.t>>,
  }

  type log = {
    kind: string,
    message: string,
  }

  // One routed instruction; `block` and `transaction` are materialised from
  // the per-chain stores at batch prep.
  type item = {
    onEventRegistrationIndex: int,
    slot: int,
    transactionIndex: int,
    instructionAddress: array<int>,
    programId: string,
    accounts: array<string>,
    data: string,
    d1?: string,
    d2?: string,
    d4?: string,
    d8?: string,
    isInner: bool,
    decoded?: ResponseTypes.decodedInstruction,
    // Present only when the routed registration opted in via `includeLogs`.
    logs?: array<log>,
  }

  type response = {
    nextSlot: int,
    // One lean header per slot referenced by `items`; the full blocks live in
    // the block store returned alongside.
    blocks: array<ResponseTypes.block>,
    items: array<item>,
  }
}

type query = QueryTypes.query
type queryResponse = ResponseTypes.queryResponse

type t = {
  getHeight: unit => promise<int>,
  // Block-data range queries only; the store pages it returns are empty.
  get: (~query: query) => promise<(queryResponse, TransactionStore.t, BlockStore.t)>,
  // Returns the routed items plus pages of raw transactions and blocks (kept
  // in Rust), keyed by (slot, transactionIndex) / slot, materialised at batch
  // prep.
  getEventItems: (
    ~query: EventItems.query,
  ) => promise<(EventItems.response, TransactionStore.t, BlockStore.t)>,
}

@send
external classFromConfig: (
  Core.svmHyperSyncClientCtor,
  cfg,
  string,
  array<Registration.input>,
) => t = "fromConfig"

let make = (
  ~url,
  ~apiToken=?,
  ~httpReqTimeoutMillis=?,
  ~maxNumRetries=?,
  ~retryBaseMs=?,
  ~retryCeilingMs=?,
  ~eventRegistrations=[],
) => {
  let envioVersion = Utils.EnvioPackage.value.version
  Core.getAddon().svmHyperSyncClient->classFromConfig(
    {
      url,
      ?apiToken,
      ?httpReqTimeoutMillis,
      ?maxNumRetries,
      ?retryBaseMs,
      ?retryCeilingMs,
    },
    `hyperindex/${envioVersion}`,
    eventRegistrations,
  )
}
