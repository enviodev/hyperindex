type paramMeta = Internal.paramMeta

let paramMetaSchema = S.recursive(self =>
  S.object((s): paramMeta => {
    name: s.field("name", S.string),
    abiType: s.field("abiType", S.string),
    indexed: s.fieldOr("indexed", S.bool, false),
    components: ?s.field("components", S.option(S.array(self))),
  })
)

// Normalize a value that could be a single item or an array into an array
let normalizeOrThrow: 'a => array<'a> = value => {
  if Array.isArray(value->Obj.magic) {
    value->Obj.magic
  } else {
    [value]
  }
}

// ============== ABI type parsing ==============

// Split a tuple type string like "(address,uint256,(bool,string))" into component types,
// respecting nested parentheses
let splitTupleComponents = (inner: string): array<string> => {
  let components = []
  let depth = ref(0)
  let start = ref(0)
  for i in 0 to inner->String.length - 1 {
    let ch = inner->String.charAt(i)
    if ch == "(" {
      depth := depth.contents + 1
    } else if ch == ")" {
      depth := depth.contents - 1
    } else if ch == "," && depth.contents == 0 {
      components->Array.push(inner->String.slice(~start=start.contents, ~end=i))->ignore
      start := i + 1
    }
  }

  // Last component
  if start.contents < inner->String.length {
    components
    ->Array.push(inner->String.slice(~start=start.contents))
    ->ignore
  }
  components
}

// ============== ABI type → S.schema mapping ==============

let rec abiTypeToSchema = (abiType: string): S.t<unknown> => {
  // Handle array types: "type[]" or "type[N]"
  if abiType->String.endsWith("]") {
    let bracketIdx = abiType->String.lastIndexOf("[")
    let baseType = abiType->String.slice(~start=0, ~end=bracketIdx)
    S.array(abiTypeToSchema(baseType))->S.toUnknown
  } else if abiType->String.startsWith("(") && abiType->String.endsWith(")") {
    // Tuple type: "(type1,type2,...)"
    let inner = abiType->String.slice(~start=1, ~end=abiType->String.length - 1)
    let components = splitTupleComponents(inner)
    let schemas = components->Array.map(c => abiTypeToSchema(c->String.trim))
    S.tuple(s => {
      schemas->Array.mapWithIndex((schema, i) => s.item(i, schema))
    })->S.toUnknown
  } else {
    switch abiType {
    | "address" => Address.schema->S.toUnknown
    | "bool" => S.bool->S.toUnknown
    | "string" | "bytes" => S.string->S.toUnknown
    | t if t->String.startsWith("uint") => Utils.BigInt.schema->S.toUnknown
    | t if t->String.startsWith("int") => Utils.BigInt.schema->S.toUnknown
    | t if t->String.startsWith("bytes") => S.string->S.toUnknown
    | other => JsError.throwWithMessage(`Unsupported ABI type: ${other}`)
    }
  }
}

// ABI type → schema for simulate items (accepts native JS values, not string-encoded)
let rec abiTypeToSimulateSchema = (abiType: string): S.t<unknown> => {
  if abiType->String.endsWith("]") {
    let bracketIdx = abiType->String.lastIndexOf("[")
    let baseType = abiType->String.slice(~start=0, ~end=bracketIdx)
    S.array(abiTypeToSimulateSchema(baseType))->S.toUnknown
  } else if abiType->String.startsWith("(") && abiType->String.endsWith(")") {
    let inner = abiType->String.slice(~start=1, ~end=abiType->String.length - 1)
    let components = splitTupleComponents(inner)
    let schemas = components->Array.map(c => abiTypeToSimulateSchema(c->String.trim))
    S.tuple(s => {
      schemas->Array.mapWithIndex((schema, i) => s.item(i, schema))
    })->S.toUnknown
  } else {
    switch abiType {
    | "address" => S.string->S.toUnknown
    | "bool" => S.bool->S.toUnknown
    | "string" | "bytes" => S.string->S.toUnknown
    | t if t->String.startsWith("uint") => S.bigint->S.toUnknown
    | t if t->String.startsWith("int") => S.bigint->S.toUnknown
    | t if t->String.startsWith("bytes") => S.string->S.toUnknown
    | other => JsError.throwWithMessage(`Unsupported ABI type: ${other}`)
    }
  }
}

// ============== ABI type → default value for simulate ==============

let rec abiTypeToDefaultValue = (abiType: string): unknown => {
  if abiType->String.endsWith("]") {
    []->(Utils.magic: array<unknown> => unknown)
  } else if abiType->String.startsWith("(") && abiType->String.endsWith(")") {
    let inner = abiType->String.slice(~start=1, ~end=abiType->String.length - 1)
    let components = splitTupleComponents(inner)
    components
    ->Array.map(c => abiTypeToDefaultValue(c->String.trim))
    ->(Utils.magic: array<unknown> => unknown)
  } else {
    switch abiType {
    | "address" =>
      Address.unsafeFromString("0x0000000000000000000000000000000000000000")->(
        Utils.magic: Address.t => unknown
      )

    | "bool" => false->(Utils.magic: bool => unknown)
    | "string" | "bytes" => ""->(Utils.magic: string => unknown)
    | t if t->String.startsWith("uint") => 0n->(Utils.magic: bigint => unknown)
    | t if t->String.startsWith("int") => 0n->(Utils.magic: bigint => unknown)
    | t if t->String.startsWith("bytes") => ""->(Utils.magic: string => unknown)
    | _ => %raw(`undefined`)->(Utils.magic: 'a => unknown)
    }
  }
}

// ============== Named-tuple (struct) schema helpers ==============

// Build an object schema that honours component names: whenever an event param
// (or nested field) has components, decode/serialize it as an object with
// named fields rather than a positional tuple. Walks through array wrappers so
// `struct[]` still produces `array<{...}>`. `~leafSchema` picks the per-ABI
// schema for non-tuple leaves (raw-event vs simulate variants differ in how
// they accept primitives — string-encoded numbers vs native bigints).
let rec componentsToObjectSchema = (
  ~leafSchema: string => S.t<unknown>,
  abiType: string,
  components: array<paramMeta>,
): S.t<unknown> => {
  if abiType->String.endsWith("]") {
    let bracketIdx = abiType->String.lastIndexOf("[")
    let baseType = abiType->String.slice(~start=0, ~end=bracketIdx)
    S.array(componentsToObjectSchema(~leafSchema, baseType, components))->S.toUnknown
  } else {
    S.object(s => {
      let dict = Dict.make()
      components->Array.forEach(c => {
        let childSchema = switch c.components {
        | Some(sub) => componentsToObjectSchema(~leafSchema, c.abiType, sub)
        | None => leafSchema(c.abiType)
        }
        dict->Dict.set(c.name, s.field(c.name, childSchema))
      })
      dict
    })->S.toUnknown
  }
}

// Default simulate value for a component tree — mirrors `abiTypeToDefaultValue`
// but emits objects with named fields for tuples.
let rec componentsToDefaultValue = (abiType: string, components: array<paramMeta>): unknown => {
  if abiType->String.endsWith("]") {
    []->(Utils.magic: array<unknown> => unknown)
  } else {
    let dict = Dict.make()
    components->Array.forEach(c => {
      let v = switch c.components {
      | Some(sub) => componentsToDefaultValue(c.abiType, sub)
      | None => abiTypeToDefaultValue(c.abiType)
      }
      dict->Dict.set(c.name, v)
    })
    dict->(Utils.magic: dict<unknown> => unknown)
  }
}

// ============== Build paramsRawEventSchema ==============

let buildParamsSchema = (params: array<paramMeta>): S.t<Internal.eventParams> => {
  if params->Array.length == 0 {
    S.literal(%raw(`null`))
    ->S.shape(_ => ())
    ->(Utils.magic: S.t<unit> => S.t<Internal.eventParams>)
  } else {
    S.object(s => {
      let dict = Dict.make()
      params->Array.forEach(p => {
        // Indexed structs arrive as keccak256 topic hashes (single hex
        // strings), so they keep the positional/leaf path; only non-indexed
        // tuple params get the named-object shape that the HyperSync decoder
        // (componentsToRemapper) produces.
        let paramSchema = switch p.components {
        | Some(components) if !p.indexed =>
          componentsToObjectSchema(~leafSchema=abiTypeToSchema, p.abiType, components)
        | _ => abiTypeToSchema(p.abiType)
        }
        dict->Dict.set(p.name, s.field(p.name, paramSchema))
      })
      dict
    })->(Utils.magic: S.t<dict<unknown>> => S.t<Internal.eventParams>)
  }
}

// Build a lenient params schema for simulate items.
// Uses S.schema + s.matches with S.null->S.Option.getOr to fill missing fields with defaults.
// When a param carries component metadata (Solidity struct), we accept and emit a
// record with named fields rather than a positional tuple.
let buildSimulateParamsSchema = (params: array<paramMeta>): S.t<Internal.eventParams> => {
  if params->Array.length == 0 {
    S.unknown
    ->S.shape(_ => ())
    ->(Utils.magic: S.t<unit> => S.t<Internal.eventParams>)
  } else {
    S.schema(s => {
      let dict = Dict.make()
      params->Array.forEach(p => {
        let (paramSchema, paramDefault) = switch p.components {
        | Some(components) => (
            componentsToObjectSchema(~leafSchema=abiTypeToSimulateSchema, p.abiType, components),
            componentsToDefaultValue(p.abiType, components),
          )
        | None => (abiTypeToSimulateSchema(p.abiType), abiTypeToDefaultValue(p.abiType))
        }
        dict->Dict.set(p.name, s.matches(S.null(paramSchema)->S.Option.getOr(paramDefault)))
      })
      dict
    })->(Utils.magic: S.t<dict<unknown>> => S.t<Internal.eventParams>)
  }
}

// ============== Build topic filter getters ==============

let getTopicEncoder = (abiType: string): (unknown => EvmTypes.Hex.t) => {
  // Handle array/tuple types - these get keccak256'd
  if abiType->String.endsWith("]") || abiType->String.startsWith("(") {
    TopicFilter.castToHexUnsafe->(Utils.magic: ('a => EvmTypes.Hex.t) => unknown => EvmTypes.Hex.t)
  } else {
    switch abiType {
    | "address" =>
      TopicFilter.fromAddress->(
        Utils.magic: (Address.t => EvmTypes.Hex.t) => unknown => EvmTypes.Hex.t
      )

    | "bool" =>
      TopicFilter.fromBool->(Utils.magic: (bool => EvmTypes.Hex.t) => unknown => EvmTypes.Hex.t)
    | "string" =>
      TopicFilter.fromDynamicString->(
        Utils.magic: (string => EvmTypes.Hex.t) => unknown => EvmTypes.Hex.t
      )

    | "bytes" =>
      TopicFilter.fromDynamicBytes->(
        Utils.magic: (string => EvmTypes.Hex.t) => unknown => EvmTypes.Hex.t
      )

    | t if t->String.startsWith("uint") =>
      TopicFilter.fromBigInt->(Utils.magic: (bigint => EvmTypes.Hex.t) => unknown => EvmTypes.Hex.t)
    | t if t->String.startsWith("int") =>
      TopicFilter.fromSignedBigInt->(
        Utils.magic: (bigint => EvmTypes.Hex.t) => unknown => EvmTypes.Hex.t
      )

    | t if t->String.startsWith("bytes") =>
      TopicFilter.castToHexUnsafe->(
        Utils.magic: ('a => EvmTypes.Hex.t) => unknown => EvmTypes.Hex.t
      )

    | other => JsError.throwWithMessage(`Unsupported topic filter ABI type: ${other}`)
    }
  }
}

let buildTopicGetter = (p: paramMeta) => {
  let encoder = getTopicEncoder(p.abiType)
  (eventFilter: dict<JSON.t>) =>
    eventFilter
    ->Utils.Dict.dangerouslyGetNonOption(p.name)
    ->Option.mapOr([], topicFilters =>
      topicFilters->(Utils.magic: JSON.t => unknown)->normalizeOrThrow->Array.map(encoder)
    )
}

// ============== Field selection ==============

// Always-included block fields (number, timestamp, hash) are prepended
// at runtime so they're always present regardless of config.
let alwaysIncludedBlockFields: array<Internal.evmBlockField> = [Number, Timestamp, Hash]

let resolveFieldSelection = (
  ~blockFields: option<array<Internal.evmBlockField>>,
  ~transactionFields: option<array<Internal.evmTransactionField>>,
  ~globalBlockFieldsSet: Utils.Set.t<Internal.evmBlockField>,
  ~globalTransactionFieldsSet: Utils.Set.t<Internal.evmTransactionField>,
) => {
  let selectedBlockFields = switch blockFields {
  | Some(fields) => Utils.Set.fromArray(Array.concat(alwaysIncludedBlockFields, fields))
  | None => globalBlockFieldsSet
  }
  let selectedTransactionFields = switch transactionFields {
  | Some(fields) => Utils.Set.fromArray(fields)
  | None => globalTransactionFieldsSet
  }
  (selectedBlockFields, selectedTransactionFields)
}

// ============== Client-side address filter ==============

let compileAddressFilter: string => (
  Internal.eventPayload,
  int,
  dict<Internal.indexingContract>,
) => bool = %raw(`function (body) {
  return new Function("event", "blockNumber", "indexingAddresses", body);
}`)

// Body of the client-side address filter. Two analogous registered-at-or-before
// checks, ANDed: (1) for non-wildcard events, the log's srcAddress must itself be
// registered (ownership is resolved structurally by partition, but the temporal
// `effectiveStartBlock` gate lives here now); (2) a DNF of address-filtered param
// names (OR of AND-groups) for events that filter an indexed address param. The
// DNF is fixed here, so it's unrolled into one boolean expression — no per-event
// closure, loop, or array. `None` only for wildcard events without a param
// filter. Exposed for snapshotting.
// `srcAddressExpr` is the JS expression for the event's owning address: EVM and
// Fuel events expose `event.srcAddress`; SVM instructions expose `event.programId`.
let buildAddressFilterBody = (
  groups: array<array<string>>,
  ~isWildcard: bool,
  ~srcAddressExpr: string="event.srcAddress",
): option<string> => {
  let paramLeaf = name =>
    `(ic = indexingAddresses[p[${JSON.stringify(
        JSON.String(name),
      )}]]) !== undefined && ic.effectiveStartBlock <= blockNumber`
  let paramDnf = switch groups {
  | [] => None
  | _ =>
    Some(
      groups
      ->Array.map(group => "(" ++ group->Array.map(paramLeaf)->Array.join(" && ") ++ ")")
      ->Array.join(" || "),
    )
  }
  let srcLeaf = `(ic = indexingAddresses[${srcAddressExpr}]) !== undefined && ic.effectiveStartBlock <= blockNumber`
  switch (isWildcard, paramDnf) {
  | (true, None) => None
  | (true, Some(dnf)) => Some("var p = event.params, ic; return " ++ dnf ++ ";")
  | (false, None) => Some("var ic; return " ++ srcLeaf ++ ";")
  | (false, Some(dnf)) =>
    Some("var p = event.params, ic; return " ++ srcLeaf ++ " && (" ++ dnf ++ ");")
  }
}

let buildAddressFilter = (
  groups: array<array<string>>,
  ~isWildcard: bool,
  ~srcAddressExpr: string="event.srcAddress",
): option<(Internal.eventPayload, int, dict<Internal.indexingContract>) => bool> =>
  buildAddressFilterBody(groups, ~isWildcard, ~srcAddressExpr)->Option.map(compileAddressFilter)

// ============== Build complete EVM event config ==============

let buildEvmEventConfig = (
  ~contractName: string,
  ~eventName: string,
  ~sighash: string,
  ~params: array<paramMeta>,
  ~isWildcard: bool,
  ~handler: option<Internal.handler>,
  ~contractRegister: option<Internal.contractRegister>,
  ~eventFilters: option<JSON.t>,
  ~probeChainId: int,
  ~onEventBlockFilterSchema: S.t<option<unknown>>,
  ~blockFields: option<array<Internal.evmBlockField>>=?,
  ~transactionFields: option<array<Internal.evmTransactionField>>=?,
  ~startBlock: option<int>=?,
  ~globalBlockFieldsSet: Utils.Set.t<Internal.evmBlockField>=Utils.Set.make(),
  ~globalTransactionFieldsSet: Utils.Set.t<Internal.evmTransactionField>=Utils.Set.make(),
): Internal.evmEventConfig => {
  let topicCount = params->Array.reduce(1, (acc, p) => p.indexed ? acc + 1 : acc)
  let indexedParams = params->Array.filter(p => p.indexed)

  let {
    getEventFiltersOrThrow,
    filterByAddresses,
    addressFilterParamGroups,
    startBlock: whereStartBlock,
  } = LogSelection.parseEventFiltersOrThrow(
    ~eventFilters,
    ~sighash,
    ~params=indexedParams->Array.map(p => p.name),
    ~contractName,
    ~probeChainId,
    ~onEventBlockFilterSchema,
    ~topic1=?indexedParams->Array.get(0)->Option.map(buildTopicGetter),
    ~topic2=?indexedParams->Array.get(1)->Option.map(buildTopicGetter),
    ~topic3=?indexedParams->Array.get(2)->Option.map(buildTopicGetter),
  )

  // `where.block.number._gte` overrides the contract-level startBlock
  // when present. The user opts into this explicitly in handler code so
  // it should win over the `config.yaml` contract `start_block`; absent
  // `where.block`, the caller's contract-level value passes through.
  let resolvedStartBlock = switch whereStartBlock {
  | Some(_) as sb => sb
  | None => startBlock
  }

  let (selectedBlockFields, selectedTransactionFields) = resolveFieldSelection(
    ~blockFields,
    ~transactionFields,
    ~globalBlockFieldsSet,
    ~globalTransactionFieldsSet,
  )

  {
    id: sighash ++ "_" ++ topicCount->Int.toString,
    name: eventName,
    contractName,
    isWildcard,
    handler,
    contractRegister,
    paramsRawEventSchema: buildParamsSchema(params),
    simulateParamsSchema: buildSimulateParamsSchema(params),
    getEventFiltersOrThrow,
    filterByAddresses,
    clientAddressFilter: ?buildAddressFilter(addressFilterParamGroups, ~isWildcard),
    dependsOnAddresses: !isWildcard || filterByAddresses,
    startBlock: resolvedStartBlock,
    selectedBlockFields,
    selectedTransactionFields,
    sighash,
    topicCount,
    paramsMetadata: params,
  }
}

// ============== Build Fuel event config ==============

let buildSvmInstructionEventConfig = (
  ~contractName: string,
  ~instructionName: string,
  ~programId: SvmTypes.Pubkey.t,
  ~discriminator: option<string>,
  ~discriminatorByteLen: int,
  ~includeTransaction: bool,
  ~includeLogs: bool,
  ~includeTokenBalances: bool,
  ~accountFilters: array<Internal.svmAccountFilterGroup>,
  ~isInner: option<bool>,
  ~isWildcard: bool,
  ~handler: option<Internal.handler>,
  ~contractRegister: option<Internal.contractRegister>,
  ~accounts: array<string>=[],
  ~args: JSON.t=JSON.Null,
  ~definedTypes: JSON.t=JSON.Null,
  ~startBlock: option<int>=?,
): Internal.svmInstructionEventConfig => {
  let paramsSchema =
    S.json(~validate=false)
    ->Utils.Schema.coerceToJsonPgType
    ->(Utils.magic: S.t<JSON.t> => S.t<Internal.eventParams>)
  {
    id: switch discriminator {
    | Some(d) => d
    | None => "none"
    },
    name: instructionName,
    contractName,
    isWildcard,
    handler,
    contractRegister,
    paramsRawEventSchema: paramsSchema,
    simulateParamsSchema: paramsSchema,
    filterByAddresses: false,
    dependsOnAddresses: !isWildcard,
    clientAddressFilter: ?buildAddressFilter([], ~isWildcard, ~srcAddressExpr="event.programId"),
    startBlock,
    programId,
    discriminator,
    discriminatorByteLen,
    includeTransaction,
    includeLogs,
    includeTokenBalances,
    accountFilters,
    isInner,
    accounts,
    args,
    definedTypes,
  }
}

let buildFuelEventConfig = (
  ~contractName: string,
  ~eventName: string,
  ~kind: string,
  ~sighash: string,
  ~rawAbi: JSON.t,
  ~isWildcard: bool,
  ~handler: option<Internal.handler>,
  ~contractRegister: option<Internal.contractRegister>,
  ~startBlock: option<int>=?,
): Internal.fuelEventConfig => {
  let fuelKind = switch kind {
  | "logData" =>
    // Transpile raw Fuel ABI to the format expected by the vendored ABI coder
    let abi = FuelSDK.transpileAbi(rawAbi)
    Internal.LogData({
      logId: sighash,
      decode: FuelSDK.Receipt.getLogDataDecoder(~abi, ~logId=sighash),
    })
  | "mint" => Mint
  | "burn" => Burn
  | "transfer" => Transfer
  | "call" => Call
  | other => JsError.throwWithMessage(`Unsupported Fuel event kind: ${other}`)
  }
  let paramsSchema = switch kind {
  | "mint" | "burn" =>
    Internal.fuelSupplyParamsSchema->(
      Utils.magic: S.t<Internal.fuelSupplyParams> => S.t<Internal.eventParams>
    )

  | "transfer" | "call" =>
    Internal.fuelTransferParamsSchema->(
      Utils.magic: S.t<Internal.fuelTransferParams> => S.t<Internal.eventParams>
    )

  | "logData" =>
    S.json(~validate=false)
    ->Utils.Schema.coerceToJsonPgType
    ->(Utils.magic: S.t<JSON.t> => S.t<Internal.eventParams>)
  | other => JsError.throwWithMessage(`Unsupported Fuel event kind: ${other}`)
  }
  {
    id: switch kind {
    | "logData" => sighash
    | other => other
    },
    name: eventName,
    contractName,
    isWildcard,
    handler,
    contractRegister,
    paramsRawEventSchema: paramsSchema,
    simulateParamsSchema: paramsSchema,
    filterByAddresses: false,
    dependsOnAddresses: !isWildcard,
    clientAddressFilter: ?buildAddressFilter([], ~isWildcard),
    startBlock,
    kind: fuelKind,
  }
}
