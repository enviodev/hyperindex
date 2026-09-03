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

let getTopicEncoder = (abiType: string): (unknown => EvmTypes.Hex.t) =>
  value => Core.getAddon().encodeIndexedTopic(~abiType, ~value)

let buildTopicGetter = (p: paramMeta) => {
  let encoder = getTopicEncoder(p.abiType)
  let isTuple = p.abiType->String.startsWith("(")
  (eventFilter: dict<JSON.t>) =>
    eventFilter
    ->Utils.Dict.dangerouslyGetNonOption(p.name)
    ->Option.mapOr([], topicFilters => {
      let raw = topicFilters->(Utils.magic: JSON.t => unknown)

      // A tuple filter value is itself an array, so a directly-passed tuple is
      // indistinguishable from an OR-list by shape alone. A single tuple is
      // the common case, so try it first; when the value doesn't ABI-encode as
      // one tuple it must be an OR-list of tuples.
      if isTuple {
        switch encoder(raw) {
        | encoded => [encoded]
        | exception _ => raw->normalizeOrThrow->Array.map(encoder)
        }
      } else {
        raw->normalizeOrThrow->Array.map(encoder)
      }
    })
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
  Internal.makeFieldSelection(
    ~blockFields=selectedBlockFields->(
      Utils.magic: Utils.Set.t<Internal.evmBlockField> => Utils.Set.t<string>
    ),
    ~transactionFields=selectedTransactionFields->(
      Utils.magic: Utils.Set.t<Internal.evmTransactionField> => Utils.Set.t<string>
    ),
    ~blockMaskFn=Evm.eventBlockFieldMask,
    ~transactionMaskFn=Evm.eventTransactionFieldMask,
  )
}

// `block.number` is the item's own key, so an inline selection carries it
// whether or not the handler listed it. Nothing else is added: dropping
// `timestamp`/`hash` is the point of naming fields inline, and the two things
// that read them off the payload cope — the progress-latency metric
// (`ChainState.applyBatchProgress`) skips a batch whose last block has no
// timestamp, and `raw_events` selects them back below.
let internalBlockFields = ["number"]

// `toRawEvent` reads `block.hash`/`block.timestamp` for the `raw_events` row's
// own columns, which are not nullable. They stay out of the row's stored
// `block_fields` (`Evm.cleanUpRawEventFieldsInPlace` strips number/timestamp/
// hash from it), so the column still holds exactly what the registration
// selected.
let rawEventBlockFields = ["hash", "timestamp"]

let evmSelectionKinds = ["block", "transaction"]
let svmSelectionKinds = ["instruction", "transaction", "accountActivity", "block", "log"]

// A handler written in plain JS gets no type error for a `blocks`/`transactions`
// typo, and an unrecognised key would read as an empty selection — silently
// dropping every field `config.yaml` selected. Rejected here so the option is
// held to the same shape whether or not the project type-checks it.
let validateFieldsShapeOrThrow = (
  fields: unknown,
  ~registration: string,
  ~validKeys: array<string>,
  ~shapeNoun: string,
) => {
  if typeof(fields) !== #object || fields === %raw(`null`) || Array.isArray(fields) {
    JsError.throwWithMessage(
      `The fields option of ${registration} must be an object of ${shapeNoun} field names.`,
    )
  }
  fields
  ->(Utils.magic: unknown => dict<unknown>)
  ->Dict.keysToArray
  ->Array.forEach(key =>
    if !(validKeys->Array.includes(key)) {
      JsError.throwWithMessage(
        `Invalid "${key}" key in the fields option of ${registration}. Valid keys: ${Utils.Array.quotedJoin(
            validKeys,
          )}.`,
      )
    }
  )
}

let selectionList = (fields: unknown, key: string): option<array<string>> =>
  switch (fields->(Utils.magic: unknown => dict<unknown>))->Dict.get(key) {
  | None => None
  | Some(value) => Some(value->(Utils.magic: unknown => array<string>))
  }

let validBlockFields = Utils.Set.fromArray(Evm.blockFields)
let validTransactionFields = Utils.Set.fromArray(Evm.transactionFields)

let parseFieldsOrThrow = (
  fields: option<array<string>>,
  ~valid: Utils.Set.t<string>,
  ~kind: string,
  ~registration: string,
  ~rejectEmpty=false,
) => {
  let seen = Utils.Set.make()
  let fields = switch fields {
  | None => []
  | Some(fields) if !Array.isArray(fields) =>
    JsError.throwWithMessage(
      `The fields.${kind} option of ${registration} must be an array of field names.`,
    )
  | Some(fields) => fields
  }
  fields->Array.forEach(name => {
    if !(valid->Utils.Set.has(name)) {
      JsError.throwWithMessage(
        `Invalid "${name}" field in the fields.${kind} option of ${registration}. Valid ${kind} fields: ${Utils.Array.quotedJoin(
          valid->Utils.Set.toArray,
        )}.`,
      )
    }
    if seen->Utils.Set.has(name) {
      JsError.throwWithMessage(
        `Duplicate "${name}" field in the fields.${kind} option of ${registration}.`,
      )
    }
    seen->Utils.Set.add(name)->ignore
  })
  if rejectEmpty && fields->Array.length === 0 {
    JsError.throwWithMessage(
      `The fields.${kind} option of ${registration} must list at least one field.`,
    )
  }
  seen
}

// Resolve an inline `fields` option into a selection. Depends only on the
// option itself (the names are for error messages), never on the chain, so one
// `onEvent` call resolves once and shares the result across every chain.
let resolveInlineFieldSelection = (
  fields: unknown,
  ~contractName: string,
  ~eventName: string,
  ~enableRawEvents: bool,
): Internal.fieldSelection => {
  let registration = `the "${eventName}" event registration on contract "${contractName}"`
  validateFieldsShapeOrThrow(
    fields,
    ~registration,
    ~validKeys=evmSelectionKinds,
    ~shapeNoun="block and transaction",
  )
  let blockFields = parseFieldsOrThrow(
    selectionList(fields, "block"),
    ~valid=validBlockFields,
    ~kind="block",
    ~registration,
  )
  let transactionFields = parseFieldsOrThrow(
    selectionList(fields, "transaction"),
    ~valid=validTransactionFields,
    ~kind="transaction",
    ~registration,
  )
  blockFields->Utils.Set.addMany(internalBlockFields)
  if enableRawEvents {
    blockFields->Utils.Set.addMany(rawEventBlockFields)
  }
  Internal.makeFieldSelection(
    ~blockFields,
    ~transactionFields,
    ~blockMaskFn=Evm.eventBlockFieldMask,
    ~transactionMaskFn=Evm.eventTransactionFieldMask,
  )
}

// ============== Build complete EVM event config ==============

let buildEvmEventConfig = (
  ~contractName: string,
  ~eventName: string,
  ~sighash: string,
  ~params: array<paramMeta>,
  ~blockFields: option<array<Internal.evmBlockField>>=?,
  ~transactionFields: option<array<Internal.evmTransactionField>>=?,
  ~globalBlockFieldsSet: Utils.Set.t<Internal.evmBlockField>=Utils.Set.make(),
  ~globalTransactionFieldsSet: Utils.Set.t<Internal.evmTransactionField>=Utils.Set.make(),
): Internal.evmEventConfig => {
  let topicCount = params->Array.reduce(1, (acc, p) => p.indexed ? acc + 1 : acc)

  {
    id: sighash ++ "_" ++ topicCount->Int.toString,
    name: eventName,
    contractName,
    paramsRawEventSchema: buildParamsSchema(params),
    simulateParamsSchema: buildSimulateParamsSchema(params),
    fieldSelection: resolveFieldSelection(
      ~blockFields,
      ~transactionFields,
      ~globalBlockFieldsSet,
      ~globalTransactionFieldsSet,
    ),
    sighash,
    topicCount,
    paramsMetadata: params,
  }
}

// Enrich an EVM definition into a per-(event,chain) registration: resolve the
// registered `where` for this chain into `resolvedWhere` + address filters,
// and override `startBlock` with `where.block._gte`.
let buildEvmOnEventRegistration = (
  ~eventConfig: Internal.evmEventConfig,
  ~isWildcard: bool,
  ~handler: option<Internal.handler>,
  ~contractRegister: option<Internal.contractRegister>,
  ~where: option<JSON.t>,
  ~chainId: ChainId.t,
  ~onEventBlockFilterSchema: S.t<option<unknown>>,
  // The registration's inline selection, already resolved; absent when it named
  // no fields and takes the event config's.
  ~fieldSelection: option<Internal.fieldSelection>=?,
  ~startBlock: option<int>=?,
): Internal.evmOnEventRegistration => {
  let indexedParams = eventConfig.paramsMetadata->Array.filter(p => p.indexed)

  let {resolvedWhere, filterByAddresses, addressFilterParamGroups} = LogSelection.parseWhereOrThrow(
    ~where,
    ~sighash=eventConfig.sighash,
    ~params=indexedParams->Array.map(p => p.name),
    ~contractName=eventConfig.contractName,
    ~chainId,
    ~onEventBlockFilterSchema,
    ~topic1=?indexedParams->Array.get(0)->Option.map(buildTopicGetter),
    ~topic2=?indexedParams->Array.get(1)->Option.map(buildTopicGetter),
    ~topic3=?indexedParams->Array.get(2)->Option.map(buildTopicGetter),
  )

  // `where.block.number._gte` overrides the contract-level startBlock when
  // present (an explicit per-event opt-in that wins over `config.yaml`);
  // otherwise the contract/chain value passes through.
  let resolvedStartBlock = switch resolvedWhere.startBlock {
  | Some(_) as sb => sb
  | None => startBlock
  }

  {
    index: -1,
    eventConfig: (eventConfig :> Internal.eventConfig),
    isWildcard,
    handler,
    contractRegister,
    resolvedWhere,
    filterByAddresses,
    addressFilterParamGroups,
    dependsOnAddresses: Internal.dependsOnAddresses(~isWildcard, ~filterByAddresses),
    startBlock: resolvedStartBlock,
    fieldSelection: switch fieldSelection {
    | Some(fieldSelection) => fieldSelection
    | None => eventConfig.fieldSelection
    },
  }
}

// ============== Build SVM instruction event config ==============

// `block.slot` is the item's own key, so an inline selection carries it
// whether or not the handler listed it.
let alwaysIncludedSvmBlockFields = ["slot"]

let validSvmInstructionFields = Utils.Set.fromArray([
  "args",
  "accounts",
  "accountArguments",
  "programId",
  "data",
  "path",
  "isInner",
])
let validSvmTransactionFields = Utils.Set.fromArray([
  "transactionIndex",
  "signature",
  "feePayer",
  "success",
  "err",
  "fee",
  "computeUnitsConsumed",
  "accountKeys",
  "recentBlockhash",
  "version",
  "allSignatures",
])
let validSvmAccountActivityFields = Utils.Set.fromArray([
  "address",
  "transactionAccountIndex",
  "isSigner",
  "isWritable",
  "lamports.pre",
  "lamports.post",
  "token.mint",
  "token.owner",
  "token.decimals",
  "token.preAmount",
  "token.postAmount",
])
let validSvmBlockFields = Utils.Set.fromArray([
  "slot",
  "time",
  "hash",
  "height",
  "parentSlot",
  "parentHash",
])
let validSvmLogFields = Utils.Set.fromArray(["kind", "message"])

let resolveSvmInlineFieldSelection = (
  fields: unknown,
  ~contractName: string,
  ~eventName: string,
): Internal.fieldSelection => {
  let registration = `the "${eventName}" instruction on program "${contractName}"`
  validateFieldsShapeOrThrow(
    fields,
    ~registration,
    ~validKeys=svmSelectionKinds,
    ~shapeNoun="instruction, transaction, accountActivity, block and log",
  )
  let accountActivity = selectionList(fields, "accountActivity")
  let log = selectionList(fields, "log")
  let instructionFields = parseFieldsOrThrow(
    selectionList(fields, "instruction"),
    ~valid=validSvmInstructionFields,
    ~kind="instruction",
    ~registration,
  )
  let transactionFields = parseFieldsOrThrow(
    selectionList(fields, "transaction"),
    ~valid=validSvmTransactionFields,
    ~kind="transaction",
    ~registration,
  )
  let accountActivityFields = parseFieldsOrThrow(
    accountActivity,
    ~valid=validSvmAccountActivityFields,
    ~kind="accountActivity",
    ~registration,
    ~rejectEmpty=accountActivity->Option.isSome,
  )
  let blockFields = parseFieldsOrThrow(
    selectionList(fields, "block"),
    ~valid=validSvmBlockFields,
    ~kind="block",
    ~registration,
  )
  let logFields = parseFieldsOrThrow(
    log,
    ~valid=validSvmLogFields,
    ~kind="log",
    ~registration,
    ~rejectEmpty=log->Option.isSome,
  )
  blockFields->Utils.Set.addMany(alwaysIncludedSvmBlockFields)
  if accountActivityFields->Utils.Set.size > 0 {
    transactionFields->Utils.Set.add("accountActivities")->ignore
  }
  Internal.makeFieldSelection(
    ~blockFields,
    ~transactionFields,
    ~instructionFields,
    ~accountActivityFields,
    ~logFields,
    ~blockMaskFn=Svm.eventBlockFieldMask,
    ~transactionMaskFn=Svm.eventTransactionFieldMask,
  )
}

let buildSvmInstructionEventConfig = (
  ~contractName: string,
  ~instructionName: string,
  ~programId: SvmTypes.Pubkey.t,
  ~discriminator: option<string>,
  ~accounts: array<string>=[],
  ~args: JSON.t=JSON.Null,
  ~definedTypes: JSON.t=JSON.Null,
): Internal.svmInstructionEventConfig => {
  let paramsSchema =
    S.json(~validate=false)
    ->Utils.Schema.coerceToJsonPgType
    ->(Utils.magic: S.t<JSON.t> => S.t<Internal.eventParams>)

  let fieldSelection = Internal.makeFieldSelection(
    ~blockFields=Utils.Set.fromArray(alwaysIncludedSvmBlockFields),
    ~transactionFields=Utils.Set.make(),
    ~blockMaskFn=Svm.eventBlockFieldMask,
    ~transactionMaskFn=Svm.eventTransactionFieldMask,
  )
  {
    id: switch discriminator {
    | Some(d) => d
    | None => "none"
    },
    name: instructionName,
    contractName,
    paramsRawEventSchema: paramsSchema,
    simulateParamsSchema: paramsSchema,
    programId,
    discriminator,
    fieldSelection,
    accounts,
    args,
    definedTypes,
  }
}

// ============== SVM `where` ==============

type parsedSvmWhere = {
  // Disjunctive normal form: outer array is OR of AND-groups. Empty means the
  // registration accepts any accounts.
  accountFilters: array<Internal.svmAccountFilterGroup>,
  isInner: option<bool>,
  startBlock: option<int>,
}

let validSvmWhereKeys = ["accounts", "isInner", "block"]

// `{slot: {_gte?}}`. Both levels are strict: the inner `eventBlockRangeSchema`
// rejects the `_lte` / `_every` that only `onSlot` supports, the outer rejects
// a wrapper key other than `slot`.
type svmBlockFilter = {slot?: LogSelection.eventBlockRange}
let svmBlockFilterSchema: S.t<svmBlockFilter> = S.object(s => {
  slot: ?s.field("slot", S.option(LogSelection.eventBlockRangeSchema)),
})->S.strict

// The source query narrows accounts through `a0..a9`, so only an instruction's
// leading account slots can be filtered.
let filterableAccountCount = 10

// Resolve the `where` option of an `onInstruction` registration. Account names
// are resolved against the instruction's declared accounts here, so the
// registration carries positions and nothing downstream needs the names.
let resolveSvmWhereOrThrow = (
  where: JSON.t,
  ~contractName: string,
  ~eventName: string,
  ~accountNames: array<string>,
): parsedSvmWhere => {
  let invalid = message =>
    JsError.throwWithMessage(
      `Invalid where configuration for the "${eventName}" instruction on program "${contractName}". ${message}`,
    )

  let obj = switch where {
  | Object(obj) => obj
  | _ => invalid("Expected an object.")
  }
  obj->Utils.Dict.forEachWithKey((_, key) =>
    if !(validSvmWhereKeys->Array.includes(key)) {
      invalid(`Unknown field "${key}". Valid fields: ${Utils.Array.quotedJoin(validSvmWhereKeys)}.`)
    }
  )

  let isInner = switch obj->Dict.get("isInner") {
  | None => None
  | Some(Boolean(isInner)) => Some(isInner)
  | Some(_) => invalid(`The "isInner" filter must be a boolean.`)
  }

  let parseGroup = (group: dict<JSON.t>): Internal.svmAccountFilterGroup =>
    group
    ->Dict.toArray
    ->Array.map(((name, value)) => {
      let position = switch accountNames->Array.indexOf(name) {
      | -1 if accountNames->Utils.Array.isEmpty =>
        invalid(
          "The instruction has no named accounts to filter on. Add `accounts` and `args` to it in config.yaml, or attach an IDL.",
        )
      | -1 =>
        invalid(
          `The instruction has no account named "${name}" to filter on. Named accounts: ${Utils.Array.quotedJoin(
              accountNames,
            )}.`,
        )
      | position if position >= filterableAccountCount =>
        invalid(
          `Account "${name}" is at position ${position->Int.toString}, and only the first ${filterableAccountCount->Int.toString} accounts of an instruction can be filtered.`,
        )
      | position => position
      }
      let values = value->normalizeOrThrow
      if values->Utils.Array.isEmpty {
        invalid(`The "${name}" filter must list at least one pubkey.`)
      }
      {
        Internal.position,
        values: values->Array.map(value =>
          switch value {
          | JSON.String(pubkey) if Core.getAddon().isSvmPubkey(~value=pubkey) =>
            pubkey->SvmTypes.Pubkey.fromStringUnsafe
          | JSON.String(pubkey) =>
            invalid(`The "${name}" filter value "${pubkey}" is not a base58 SVM pubkey.`)
          | _ => invalid(`The "${name}" filter must list base58 pubkeys as strings.`)
          }
        ),
      }
    })

  // An empty AND-group matches every instruction, so it makes the whole OR
  // vacuous. Normalized away here so the source builds one unfiltered
  // selection instead of a match-all selection beside the narrower ones.
  let groups = switch obj->Dict.get("accounts") {
  | None => []
  | Some(Object(group)) => [parseGroup(group)]
  | Some(Array(entries)) =>
    entries->Array.map(entry =>
      switch entry {
      | Object(group) => parseGroup(group)
      | _ => invalid(`Each entry in "accounts" must be an object.`)
      }
    )
  | Some(_) => invalid(`Expected "accounts" to be an object or an array of objects.`)
  }
  let accountFilters = groups->Array.some(Utils.Array.isEmpty) ? [] : groups

  let startBlock = switch obj->Dict.get("block") {
  | None => None
  | Some(block) =>
    let filter = try block->S.parseOrThrow(svmBlockFilterSchema) catch {
    | S.Raised(exn) =>
      invalid(
        `The "block" filter is invalid: ${exn
          ->Utils.prettifyExn
          ->(
            Utils.magic: exn => string
          )}. Only \`_gte\` is supported on instruction filters — use \`indexer.onSlot\` for \`_lte\` or \`_every\`.`,
      )
    }
    switch filter.slot {
    | Some({_gte}) => _gte
    | None => None
    }
  }

  {accountFilters, isInner, startBlock}
}

// Enrich an SVM definition into a registration: the handler binding plus the
// `where`-derived account/isInner filters and startBlock override.
let buildSvmOnEventRegistration = (
  ~eventConfig: Internal.svmInstructionEventConfig,
  ~isWildcard: bool,
  ~handler: option<Internal.handler>,
  ~contractRegister: option<Internal.contractRegister>,
  ~where: option<JSON.t>,
  ~fieldSelection: option<Internal.fieldSelection>=?,
  ~startBlock: option<int>=?,
): Internal.svmOnEventRegistration => {
  let resolvedWhere = switch where {
  | None => {accountFilters: [], isInner: None, startBlock: None}
  | Some(where) =>
    where->resolveSvmWhereOrThrow(
      ~contractName=eventConfig.contractName,
      ~eventName=eventConfig.name,
      ~accountNames=eventConfig.accounts,
    )
  }

  {
    index: -1,
    eventConfig: (eventConfig :> Internal.eventConfig),
    handler,
    contractRegister,
    isWildcard,
    filterByAddresses: false,
    dependsOnAddresses: Internal.dependsOnAddresses(~isWildcard, ~filterByAddresses=false),
    // `where.block.slot._gte` overrides the program-level startBlock when
    // present, mirroring EVM's `where.block.number._gte`.
    startBlock: switch resolvedWhere.startBlock {
    | Some(_) as sb => sb
    | None => startBlock
    },
    fieldSelection: switch fieldSelection {
    | Some(fieldSelection) => fieldSelection
    | None => eventConfig.fieldSelection
    },
    accountFilters: resolvedWhere.accountFilters,
    isInner: resolvedWhere.isInner,
  }
}

// ============== Build Fuel event config ==============

let buildFuelEventConfig = (
  ~contractName: string,
  ~eventName: string,
  ~kind: string,
  ~sighash: string,
  ~rawAbi: JSON.t,
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
    paramsRawEventSchema: paramsSchema,
    simulateParamsSchema: paramsSchema,
    // Fuel keeps the transaction inline on the payload, so nothing is selected
    // for it; the block is materialised from the store with the full
    // always-queried trio.
    fieldSelection: Internal.makeFieldSelection(
      ~blockFields=Utils.Set.fromArray(Fuel.blockFields),
      ~transactionFields=Utils.Set.fromArray(Fuel.transactionFields),
      ~blockMaskFn=Fuel.eventBlockFieldMask,
      ~transactionMaskFn=Fuel.eventTransactionFieldMask,
    ),
    kind: fuelKind,
  }
}

// Enrich a Fuel definition into a registration (handler binding +
// wildcard-derived address gate; Fuel never filters by addresses).
let buildFuelOnEventRegistration = (
  ~eventConfig: Internal.fuelEventConfig,
  ~isWildcard: bool,
  ~handler: option<Internal.handler>,
  ~contractRegister: option<Internal.contractRegister>,
  ~startBlock: option<int>=?,
): Internal.fuelOnEventRegistration => {
  index: -1,
  eventConfig: (eventConfig :> Internal.eventConfig),
  handler,
  contractRegister,
  isWildcard,
  filterByAddresses: false,
  dependsOnAddresses: Internal.dependsOnAddresses(~isWildcard, ~filterByAddresses=false),
  startBlock,
  fieldSelection: eventConfig.fieldSelection,
}
