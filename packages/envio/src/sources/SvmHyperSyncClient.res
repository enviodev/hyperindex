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

  // One `onInstruction`/`contractRegister` binding of an instruction on a
  // chain: the handler-specific matching state and the fetch state queries are
  // built from. Chain-scoped `index` is echoed back on matched items.
  type input = {
    index: int,
    isWildcard: bool,
    // Earliest slot this registration accepts; `None` is unrestricted.
    startBlock: option<int>,
    isInner?: bool,
    // DNF: outer array is OR of AND-groups.
    accountFilters: array<array<accountFilter>>,
    // camelCase Internal.svmTransactionField / svmBlockField names.
    transactionFields: array<string>,
    blockFields: array<string>,
    accountActivityFields: array<string>,
    logFields: array<string>,
    instructionFields: array<string>,
  }

  // One config instruction: its identity (data prefix of any length; absent
  // matches every instruction of the program) and Borsh layout, shared by
  // every registration bound to it.
  type instruction = {
    name: string,
    discriminator?: string,
    argsJson?: string,
    registrations: array<input>,
  }

  type program = {
    // The config's program name.
    name: string,
    programId: string,
    definedTypesJson?: string,
    instructions: array<instruction>,
  }

  // Groups a chain's registrations under the config instruction each was
  // built from, so the Rust client holds one layout per instruction rather
  // than a copy per registration.
  let fromOnEventRegistrations = (
    onEventRegistrations: array<Internal.svmOnEventRegistration>,
  ): array<program> => {
    let programs: array<program> = []
    onEventRegistrations->Array.forEach(reg => {
      let eventConfig =
        reg.eventConfig->(Utils.magic: Internal.eventConfig => Internal.svmInstructionEventConfig)
      let program = switch programs->Array.find(p => p.name === eventConfig.contractName) {
      | Some(program) => program
      | None =>
        let program = {
          name: eventConfig.contractName,
          programId: eventConfig.programId->SvmTypes.Pubkey.toString,
          definedTypesJson: ?switch eventConfig.definedTypes {
          | JSON.Null => None
          | definedTypes => Some(definedTypes->JSON.stringify)
          },
          instructions: [],
        }
        programs->Array.push(program)->ignore
        program
      }
      let instruction = switch program.instructions->Array.find(i => i.name === eventConfig.name) {
      | Some(instruction) => instruction
      | None =>
        let instruction = {
          name: eventConfig.name,
          discriminator: ?eventConfig.discriminator,
          argsJson: ?switch eventConfig.args {
          | JSON.Null => None
          | args => Some(args->JSON.stringify)
          },
          registrations: [],
        }
        program.instructions->Array.push(instruction)->ignore
        instruction
      }
      instruction.registrations
      ->Array.push({
        index: reg.index,
        isWildcard: reg.isWildcard,
        startBlock: reg.startBlock,
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
      })
      ->ignore
    })
    programs
  }
}

module Items = {
  // The whole per-query input: slot range and what it selects from each
  // table. Instruction selections and field selection are derived on the Rust
  // side.
  type query = {
    fromSlot: int,
    // Inclusive; None queries to the end of available data.
    toSlot: option<int>,
    onEventRegistrationIndexes: array<int>,
    onBlockRegistrationIndexes: array<int>,
    // Slots at or above this one can still be reorged, so a page reaching
    // them reads every slot of its range, which also tells a skipped slot from
    // an unfetched one. Absent when the range is final.
    reorgableFrom?: int,
  }

  // NAPI leaves a Rust `None` field of an object as `undefined`, not `null`,
  // so `Option` fields decode as `Nullable`.
  type log = {
    kind: Nullable.t<string>,
    message: Nullable.t<string>,
  }

  // One matched instruction; its `block` and `transaction` are joined by the
  // build that delivers it.
  type item = {
    slot: int,
    transactionIndex: int,
    path: array<int>,
    programId: string,
    accounts: array<string>,
    data: Uint8Array.t,
    isInner: bool,
    // Borsh-decoded args as a JS value tree (wide integers as bigint).
    // Present exactly when the matched registration selected `args`: an
    // instruction its layout rejects is dropped in Rust.
    args: Nullable.t<unknown>,
    // Present exactly when the matched registration selected `fields.log`.
    logs: Nullable.t<array<log>>,
  }

  type response = {nextSlot: int}
}

type t = {
  getHeight: unit => promise<int>,
  // Block-hash query construction, pagination, and cursor-backed skipped-slot
  // coverage live in Rust.
  getBlockHashes: (~blockNumbers: array<int>) => promise<(BufferPage.t, array<RequestStat.t>)>,
  // Returns the page of raw instructions some registration matches, with the
  // transactions and slots they read.
  getItems: (~query: Items.query) => promise<(Items.response, BufferPage.t)>,
}

@send
external classFromConfig: (
  Core.svmHyperSyncClientCtor,
  cfg,
  string,
  // The chain's compiled registrations, block handlers and addresses.
  BufferPage.buffer,
) => t = "fromConfig"

let make = (
  ~url,
  ~apiToken=?,
  ~httpReqTimeoutMillis=?,
  ~retryBaseMs=?,
  ~retryCeilingMs=?,
  ~chainBuffer,
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
    chainBuffer,
  )
}
