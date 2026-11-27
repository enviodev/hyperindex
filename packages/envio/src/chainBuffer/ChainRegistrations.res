// The chain's compiled registrations as the Rust chain buffer takes them, one
// shape per ecosystem.

module Evm = {
  // One topic position of the resolved `where`: `Some([])` matches any value,
  // `Some(values)` one of them, and `None` is the "currently registered
  // addresses of this contract" marker, expanded to padded address topics
  // when Rust builds a query.
  type topicConstraintInput = option<array<string>>

  type topicFilterInput = {
    topic0: topicConstraintInput,
    topic1: topicConstraintInput,
    topic2: topicConstraintInput,
    topic3: topicConstraintInput,
  }

  type input = {
    // Chain-scoped sequential registration index, echoed back on matched items.
    index: int,
    // `None` for an anonymous event.
    sighash: option<string>,
    topicCount: int,
    eventName: string,
    contractName: string,
    isWildcard: bool,
    dependsOnAddresses: bool,
    // Earliest block this registration accepts; `None` is unrestricted. The
    // address store's start block is contract-wide, so it can't hold one
    // registration back when a sibling declares no start block.
    startBlock: option<int>,
    params: array<Internal.paramMeta>,
    topicFilters: array<topicFilterInput>,
    // Capitalized field names matching the Rust BlockField/TransactionField
    // string enums.
    blockFields: array<string>,
    transactionFields: array<string>,
  }

  let toTopicConstraintInput = (topicConstraint: Internal.topicConstraint): topicConstraintInput =>
    switch topicConstraint {
    | Any => Some([])
    | Values(values) => Some(values->EvmTypes.Hex.toStrings)
    | ContractAddresses(_) => None
    }

  let fromOnEventRegistrations = (
    onEventRegistrations: array<Internal.evmOnEventRegistration>,
  ): array<input> => {
    onEventRegistrations->Array.map(reg => {
      let event = reg.eventConfig->(Utils.magic: Internal.eventConfig => Internal.evmEventConfig)
      {
        index: reg.index,
        sighash: event.sighash,
        topicCount: event.topicCount,
        eventName: event.name,
        contractName: event.contractName,
        isWildcard: reg.isWildcard,
        dependsOnAddresses: reg.dependsOnAddresses,
        startBlock: reg.startBlock,
        params: event.paramsMetadata,
        topicFilters: reg.resolvedWhere.topicFilters->Array.map((filter): topicFilterInput => {
          topic0: filter.topic0->toTopicConstraintInput,
          topic1: filter.topic1->toTopicConstraintInput,
          topic2: filter.topic2->toTopicConstraintInput,
          topic3: filter.topic3->toTopicConstraintInput,
        }),
        blockFields: reg.fieldSelection.blockFields
        ->Utils.Set.toArray
        ->Array.map(Utils.String.capitalize),
        transactionFields: reg.fieldSelection.transactionFields
        ->Utils.Set.toArray
        ->Array.map(Utils.String.capitalize),
      }
    })
  }
}

module Fuel = {
  type kind =
    | @as("LogData") LogData
    | @as("Mint") Mint
    | @as("Burn") Burn
    | @as("Transfer") Transfer
    | @as("Call") Call

  type input = {
    index: int,
    eventName: string,
    contractName: string,
    isWildcard: bool,
    startBlock: option<int>,
    kind: kind,
    logId?: string,
    abi?: JSON.t,
  }

  let fromOnEventRegistrations = (onEventRegistrations: array<Internal.onEventRegistration>): array<
    input,
  > =>
    onEventRegistrations->Array.map(reg => {
      let eventConfig =
        reg.eventConfig->(Utils.magic: Internal.eventConfig => Internal.fuelEventConfig)
      let (kind, logId, abi) = switch eventConfig.kind {
      | LogData({logId, abi}) => (LogData, Some(logId), Some(abi))
      | Mint => (Mint, None, None)
      | Burn => (Burn, None, None)
      | Transfer => (Transfer, None, None)
      | Call => (Call, None, None)
      }
      {
        index: reg.index,
        eventName: eventConfig.name,
        contractName: eventConfig.contractName,
        isWildcard: reg.isWildcard,
        startBlock: reg.startBlock,
        kind,
        ?logId,
        ?abi,
      }
    })
}

module Svm = {
  type accountFilter = {
    position: int,
    values: array<string>,
  }

  type input = {
    index: int,
    isWildcard: bool,
    startBlock: option<int>,
    isInner?: bool,
    accountFilters: array<array<accountFilter>>,
    transactionFields: array<string>,
    blockFields: array<string>,
    accountActivityFields: array<string>,
    logFields: array<string>,
    instructionFields: array<string>,
  }

  type instruction = {
    name: string,
    discriminator?: string,
    argsJson?: string,
    registrations: array<input>,
  }

  type program = {
    name: string,
    programId: string,
    definedTypesJson?: string,
    instructions: array<instruction>,
  }

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
