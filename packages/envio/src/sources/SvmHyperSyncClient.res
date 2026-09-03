type cfg = {
  /** HyperSync server URL. */
  url: string,
  /** Optional bearer token for the HyperSync server. */
  apiToken?: string,
  httpReqTimeoutMillis?: int,
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
    // Earliest slot this registration accepts; `None` is unrestricted.
    startBlock: option<int>,
    discriminator?: string,
    isInner?: bool,
    // DNF: outer array is OR of AND-groups.
    accountFilters: array<array<accountFilter>>,
    // camelCase Internal.svmTransactionField / svmBlockField names.
    transactionFields: array<string>,
    blockFields: array<string>,
    accountActivityFields: array<string>,
    logFields: array<string>,
    instructionFields: array<string>,
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
        startBlock: reg.startBlock,
        discriminator: ?eventConfig.discriminator,
        isInner: ?reg.isInner,
        accountFilters: reg.accountFilters->Array.map(group =>
          group->Array.map(
            (filter): accountFilter => {
              position: filter.position,
              values: filter.values->SvmTypes.Pubkey.toStrings,
            },
          )
        ),
        transactionFields: reg.fieldSelection.transactionFields->Utils.Set.toArray,
        blockFields: reg.fieldSelection.blockFields->Utils.Set.toArray,
        accountActivityFields: reg.fieldSelection.accountActivityFields->Utils.Set.toArray,
        logFields: reg.fieldSelection.logFields->Utils.Set.toArray,
        instructionFields: reg.fieldSelection.instructionFields->Utils.Set.toArray,
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

module ResponseTypes = {
  // Lean per-slot header for reorg detection and each item's slot/time; the
  // selectable fields live in the block store and are materialised on demand.
  type block = {
    slot: int,
    blockhash: string,
    blockTime: Null.t<int>,
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
    // Program names to fetch address-free even though their registrations
    // depend on addresses (client-side filtering). None/empty means every
    // address-dependent program is filtered server-side.
    clientFilteredContracts: option<array<string>>,
  }

  // NAPI encodes Rust `None` as `null`, never `undefined`, so an unselected
  // key arrives as an explicit null rather than a missing field.
  type log = {
    kind: Null.t<string>,
    message: Null.t<string>,
  }

  // One routed instruction; `block` and `transaction` are materialised from
  // the per-chain stores at batch prep.
  type item = {
    onEventRegistrationIndex: int,
    slot: int,
    transactionIndex: int,
    path: array<int>,
    programId: string,
    accounts: array<string>,
    data: Uint8Array.t,
    isInner: bool,
    // Borsh-decoded args as a JS value tree (wide integers as bigint), an
    // empty object when the routed registration reads no args. An instruction
    // the schema rejects is dropped in Rust, so a selected `args` is always
    // decoded.
    args: unknown,
    // Non-null only when the routed registration selected `fields.log`.
    logs: Null.t<array<log>>,
  }

  type response = {
    nextSlot: int,
    // One lean header per returned slot, including slots no item references —
    // reorg detection and the batch's latest timestamp read them all. The full
    // blocks live in the block store returned alongside, which keeps only the
    // slots items reference.
    blocks: array<ResponseTypes.block>,
    items: array<item>,
  }
}

type t = {
  getHeight: unit => promise<int>,
  // Block-hash query construction, pagination, and cursor-backed skipped-slot
  // coverage live in Rust.
  getBlockHashes: (~blockNumbers: array<int>) => promise<(BlockStore.t, array<RequestStat.t>)>,
  // Returns the routed items plus pages of raw transactions and blocks (kept
  // in Rust), keyed by (slot, transactionIndex) / slot, materialised at batch
  // prep.
  getEventItems: (
    ~query: EventItems.query,
    ~addressSet: AddressSet.t,
  ) => promise<(EventItems.response, TransactionStore.t, BlockStore.t)>,
}

@send
external classFromConfig: (
  Core.svmHyperSyncClientCtor,
  cfg,
  string,
  array<Registration.input>,
  AddressStore.t,
) => t = "fromConfig"

let make = (
  ~url,
  ~apiToken=?,
  ~httpReqTimeoutMillis=?,
  ~retryBaseMs=?,
  ~retryCeilingMs=?,
  ~eventRegistrations=[],
  ~addressStore,
) => {
  let envioVersion = Utils.EnvioPackage.value.version
  Core.getAddon().svmHyperSyncClient->classFromConfig(
    {
      url,
      ?apiToken,
      ?httpReqTimeoutMillis,
      ?retryBaseMs,
      ?retryCeilingMs,
    },
    `hyperindex/${envioVersion}`,
    eventRegistrations,
    addressStore,
  )
}
