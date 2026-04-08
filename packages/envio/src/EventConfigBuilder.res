open Belt

// Recursive tuple/struct component metadata emitted by the CLI when an event
// param (or any nested field) is a Solidity struct. `name` is always non-empty —
// the CLI fills in `_0`, `_1`, ... for anonymous components — so the runtime can
// always rebuild a keyed object.
type rec eventParamComponent = {
  name: string,
  abiType: string,
  components?: array<eventParamComponent>,
}

type eventParam = {
  name: string,
  abiType: string,
  indexed: bool,
  components?: array<eventParamComponent>,
}

let eventParamComponentSchema = S.recursive(self =>
  S.object((s): eventParamComponent => {
    name: s.field("name", S.string),
    abiType: s.field("abiType", S.string),
    components: ?s.field("components", S.option(S.array(self))),
  })
)

let eventParamSchema = S.object((s): eventParam => {
  name: s.field("name", S.string),
  abiType: s.field("abiType", S.string),
  indexed: s.fieldOr("indexed", S.bool, false),
  components: ?s.field("components", S.option(S.array(eventParamComponentSchema))),
})

// Normalize a value that could be a single item or an array into an array
let normalizeOrThrow: 'a => array<'a> = value => {
  if Js.Array2.isArray(value->Obj.magic) {
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
  for i in 0 to inner->Js.String2.length - 1 {
    let ch = inner->Js.String2.charAt(i)
    if ch == "(" {
      depth := depth.contents + 1
    } else if ch == ")" {
      depth := depth.contents - 1
    } else if ch == "," && depth.contents == 0 {
      components->Js.Array2.push(inner->Js.String2.slice(~from=start.contents, ~to_=i))->ignore
      start := i + 1
    }
  }

  // Last component
  if start.contents < inner->Js.String2.length {
    components
    ->Js.Array2.push(inner->Js.String2.sliceToEnd(~from=start.contents))
    ->ignore
  }
  components
}

// ============== ABI type → S.schema mapping ==============

let rec abiTypeToSchema = (abiType: string): S.t<unknown> => {
  // Handle array types: "type[]" or "type[N]"
  if abiType->Js.String2.endsWith("]") {
    let bracketIdx = abiType->Js.String2.lastIndexOf("[")
    let baseType = abiType->Js.String2.slice(~from=0, ~to_=bracketIdx)
    S.array(abiTypeToSchema(baseType))->S.toUnknown
  } else if abiType->Js.String2.startsWith("(") && abiType->Js.String2.endsWith(")") {
    // Tuple type: "(type1,type2,...)"
    let inner = abiType->Js.String2.slice(~from=1, ~to_=abiType->Js.String2.length - 1)
    let components = splitTupleComponents(inner)
    let schemas = components->Array.map(c => abiTypeToSchema(c->Js.String2.trim))
    S.tuple(s => {
      schemas->Array.mapWithIndex((i, schema) => s.item(i, schema))
    })->S.toUnknown
  } else {
    switch abiType {
    | "address" => Address.schema->S.toUnknown
    | "bool" => S.bool->S.toUnknown
    | "string" | "bytes" => S.string->S.toUnknown
    | t if t->Js.String2.startsWith("uint") => Utils.BigInt.schema->S.toUnknown
    | t if t->Js.String2.startsWith("int") => Utils.BigInt.schema->S.toUnknown
    | t if t->Js.String2.startsWith("bytes") => S.string->S.toUnknown
    | other => Js.Exn.raiseError(`Unsupported ABI type: ${other}`)
    }
  }
}

// ABI type → schema for simulate items (accepts native JS values, not string-encoded)
let rec abiTypeToSimulateSchema = (abiType: string): S.t<unknown> => {
  if abiType->Js.String2.endsWith("]") {
    let bracketIdx = abiType->Js.String2.lastIndexOf("[")
    let baseType = abiType->Js.String2.slice(~from=0, ~to_=bracketIdx)
    S.array(abiTypeToSimulateSchema(baseType))->S.toUnknown
  } else if abiType->Js.String2.startsWith("(") && abiType->Js.String2.endsWith(")") {
    let inner = abiType->Js.String2.slice(~from=1, ~to_=abiType->Js.String2.length - 1)
    let components = splitTupleComponents(inner)
    let schemas = components->Array.map(c => abiTypeToSimulateSchema(c->Js.String2.trim))
    S.tuple(s => {
      schemas->Array.mapWithIndex((i, schema) => s.item(i, schema))
    })->S.toUnknown
  } else {
    switch abiType {
    | "address" => S.string->S.toUnknown
    | "bool" => S.bool->S.toUnknown
    | "string" | "bytes" => S.string->S.toUnknown
    | t if t->Js.String2.startsWith("uint") => S.bigint->S.toUnknown
    | t if t->Js.String2.startsWith("int") => S.bigint->S.toUnknown
    | t if t->Js.String2.startsWith("bytes") => S.string->S.toUnknown
    | other => Js.Exn.raiseError(`Unsupported ABI type: ${other}`)
    }
  }
}

// ============== ABI type → default value for simulate ==============

let rec abiTypeToDefaultValue = (abiType: string): unknown => {
  if abiType->Js.String2.endsWith("]") {
    []->(Utils.magic: array<unknown> => unknown)
  } else if abiType->Js.String2.startsWith("(") && abiType->Js.String2.endsWith(")") {
    let inner = abiType->Js.String2.slice(~from=1, ~to_=abiType->Js.String2.length - 1)
    let components = splitTupleComponents(inner)
    components
    ->Array.map(c => abiTypeToDefaultValue(c->Js.String2.trim))
    ->(Utils.magic: array<unknown> => unknown)
  } else {
    switch abiType {
    | "address" =>
      Address.unsafeFromString("0x0000000000000000000000000000000000000000")->(
        Utils.magic: Address.t => unknown
      )

    | "bool" => false->(Utils.magic: bool => unknown)
    | "string" | "bytes" => ""->(Utils.magic: string => unknown)
    | t if t->Js.String2.startsWith("uint") => 0n->(Utils.magic: bigint => unknown)
    | t if t->Js.String2.startsWith("int") => 0n->(Utils.magic: bigint => unknown)
    | t if t->Js.String2.startsWith("bytes") => ""->(Utils.magic: string => unknown)
    | _ => %raw(`undefined`)->(Utils.magic: 'a => unknown)
    }
  }
}

// ============== Named-tuple (struct) schema helpers ==============

// Build a simulate schema that honours component names: whenever an event param
// (or nested field) has components, we decode it as an object with named fields
// rather than a positional tuple. Walks through array wrappers so `struct[]`
// still produces `array<{...}>`.
let rec componentsToSimulateSchema = (abiType: string, components: array<eventParamComponent>): S.t<
  unknown,
> => {
  if abiType->Js.String2.endsWith("]") {
    let bracketIdx = abiType->Js.String2.lastIndexOf("[")
    let baseType = abiType->Js.String2.slice(~from=0, ~to_=bracketIdx)
    S.array(componentsToSimulateSchema(baseType, components))->S.toUnknown
  } else {
    // Must be a tuple at this level: build a record keyed by component names.
    S.object(s => {
      let dict = Js.Dict.empty()
      components->Array.forEach(c => {
        let childSchema = switch c.components {
        | Some(sub) => componentsToSimulateSchema(c.abiType, sub)
        | None => abiTypeToSimulateSchema(c.abiType)
        }
        dict->Js.Dict.set(c.name, s.field(c.name, childSchema))
      })
      dict
    })->S.toUnknown
  }
}

// Default simulate value for a component tree — mirrors `abiTypeToDefaultValue`
// but emits objects with named fields for tuples.
let rec componentsToDefaultValue = (
  abiType: string,
  components: array<eventParamComponent>,
): unknown => {
  if abiType->Js.String2.endsWith("]") {
    []->(Utils.magic: array<unknown> => unknown)
  } else {
    let dict = Js.Dict.empty()
    components->Array.forEach(c => {
      let v = switch c.components {
      | Some(sub) => componentsToDefaultValue(c.abiType, sub)
      | None => abiTypeToDefaultValue(c.abiType)
      }
      dict->Js.Dict.set(c.name, v)
    })
    dict->(Utils.magic: Js.Dict.t<unknown> => unknown)
  }
}

// Build a post-processor that converts the raw positional tuple values
// produced by the HyperSync decoder into objects with named fields. Walks
// through array wrappers so `struct[]` becomes `array<{...}>`. Returns `None`
// for leaf params where no remapping is needed.
let rec componentsToRemapper = (
  abiType: string,
  components: array<eventParamComponent>,
  value: unknown,
): unknown => {
  if abiType->Js.String2.endsWith("]") {
    let bracketIdx = abiType->Js.String2.lastIndexOf("[")
    let baseType = abiType->Js.String2.slice(~from=0, ~to_=bracketIdx)
    let arr = value->(Utils.magic: unknown => array<unknown>)
    arr
    ->Array.map(item => componentsToRemapper(baseType, components, item))
    ->(Utils.magic: array<unknown> => unknown)
  } else {
    // Must be a tuple at this level: build an object keyed by component names.
    let arr = value->(Utils.magic: unknown => array<unknown>)
    let dict = Js.Dict.empty()
    components->Array.forEachWithIndex((i, c) => {
      let raw = arr->Array.getUnsafe(i)
      let mapped = switch c.components {
      | Some(sub) => componentsToRemapper(c.abiType, sub, raw)
      | None => raw
      }
      dict->Js.Dict.set(c.name, mapped)
    })
    dict->(Utils.magic: Js.Dict.t<unknown> => unknown)
  }
}

// ============== Build paramsRawEventSchema ==============

let buildParamsSchema = (params: array<eventParam>): S.t<Internal.eventParams> => {
  if params->Array.length == 0 {
    S.literal(%raw(`null`))
    ->S.shape(_ => ())
    ->(Utils.magic: S.t<unit> => S.t<Internal.eventParams>)
  } else {
    S.object(s => {
      let dict = Js.Dict.empty()
      params->Array.forEach(p => {
        dict->Js.Dict.set(p.name, s.field(p.name, abiTypeToSchema(p.abiType)))
      })
      dict
    })->(Utils.magic: S.t<dict<unknown>> => S.t<Internal.eventParams>)
  }
}

// Build a lenient params schema for simulate items.
// Uses S.schema + s.matches with S.null->S.Option.getOr to fill missing fields with defaults.
// When a param carries component metadata (Solidity struct), we accept and emit a
// record with named fields rather than a positional tuple.
let buildSimulateParamsSchema = (params: array<eventParam>): S.t<Internal.eventParams> => {
  if params->Array.length == 0 {
    S.unknown
    ->S.shape(_ => ())
    ->(Utils.magic: S.t<unit> => S.t<Internal.eventParams>)
  } else {
    S.schema(s => {
      let dict = Js.Dict.empty()
      params->Array.forEach(p => {
        let (paramSchema, paramDefault) = switch p.components {
        | Some(components) => (
            componentsToSimulateSchema(p.abiType, components),
            componentsToDefaultValue(p.abiType, components),
          )
        | None => (abiTypeToSimulateSchema(p.abiType), abiTypeToDefaultValue(p.abiType))
        }
        dict->Js.Dict.set(p.name, s.matches(S.null(paramSchema)->S.Option.getOr(paramDefault)))
      })
      dict
    })->(Utils.magic: S.t<dict<unknown>> => S.t<Internal.eventParams>)
  }
}

// ============== Build HyperSync decoder via new Function() ==============

// Param names from ABI are valid Solidity identifiers ([a-zA-Z_$][a-zA-Z0-9_$]*),
// so they're safe to use in quoted property names within new Function() body.
@new @variadic
external makeFunction: array<string> => 'a = "Function"

let buildHyperSyncDecoder = (params: array<eventParam>): (
  HyperSyncClient.Decoder.decodedEvent => Internal.eventParams
) => {
  if params->Array.length == 0 {
    _ => ()->(Utils.magic: unit => Internal.eventParams)
  } else {
    let indexedParams = params->Js.Array2.filter(p => p.indexed)
    let bodyParams = params->Js.Array2.filter(p => !p.indexed)

    let fields = []
    indexedParams->Array.forEachWithIndex((i, p) => {
      fields->Js.Array2.push(`"${p.name}": t(d.indexed[${i->Int.toString}])`)->ignore
    })
    bodyParams->Array.forEachWithIndex((i, p) => {
      fields->Js.Array2.push(`"${p.name}": t(d.body[${i->Int.toString}])`)->ignore
    })
    // Generate: function(t) { return function(d) { return { ... } } }
    let body = `return function(d) { return {${fields->Js.Array2.joinWith(", ")}} }`

    let factory: (
      HyperSyncClient.Decoder.decodedRaw => HyperSyncClient.Decoder.decodedUnderlying
    ) => HyperSyncClient.Decoder.decodedEvent => Internal.eventParams =
      makeFunction(["t", body])->(
        Utils.magic: 'a => (
          HyperSyncClient.Decoder.decodedRaw => HyperSyncClient.Decoder.decodedUnderlying
        ) => HyperSyncClient.Decoder.decodedEvent => Internal.eventParams
      )

    let baseDecode = factory(HyperSyncClient.Decoder.toUnderlying)

    // For any param that has tuple component metadata, rewrite its value from a
    // positional array into a named record post-decode. We pre-collect the
    // params that need remapping so the hot path only walks those. Indexed
    // struct/tuple params arrive as keccak256 topic hashes (single hex strings)
    // rather than positional arrays, so they must be skipped here — running
    // componentsToRemapper on a hash would treat the hex string as an array
    // and read garbage.
    let paramsToRemap = params->Js.Array2.filter(p => !p.indexed && p.components->Option.isSome)

    if paramsToRemap->Array.length == 0 {
      baseDecode
    } else {
      decoded => {
        let result = baseDecode(decoded)
        let dict = result->(Utils.magic: Internal.eventParams => Js.Dict.t<unknown>)
        paramsToRemap->Array.forEach(p => {
          switch (p.components, dict->Js.Dict.get(p.name)) {
          | (Some(components), Some(raw)) =>
            dict->Js.Dict.set(p.name, componentsToRemapper(p.abiType, components, raw))
          | _ => ()
          }
        })
        dict->(Utils.magic: Js.Dict.t<unknown> => Internal.eventParams)
      }
    }
  }
}

// ============== Build topic filter getters ==============

let getTopicEncoder = (abiType: string): (unknown => EvmTypes.Hex.t) => {
  // Handle array/tuple types - these get keccak256'd
  if abiType->Js.String2.endsWith("]") || abiType->Js.String2.startsWith("(") {
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

    | t if t->Js.String2.startsWith("uint") =>
      TopicFilter.fromBigInt->(Utils.magic: (bigint => EvmTypes.Hex.t) => unknown => EvmTypes.Hex.t)
    | t if t->Js.String2.startsWith("int") =>
      TopicFilter.fromSignedBigInt->(
        Utils.magic: (bigint => EvmTypes.Hex.t) => unknown => EvmTypes.Hex.t
      )

    | t if t->Js.String2.startsWith("bytes") =>
      TopicFilter.castToHexUnsafe->(
        Utils.magic: ('a => EvmTypes.Hex.t) => unknown => EvmTypes.Hex.t
      )

    | other => Js.Exn.raiseError(`Unsupported topic filter ABI type: ${other}`)
    }
  }
}

let buildTopicGetter = (p: eventParam) => {
  let encoder = getTopicEncoder(p.abiType)
  (eventFilter: Js.Dict.t<Js.Json.t>) =>
    eventFilter
    ->Utils.Dict.dangerouslyGetNonOption(p.name)
    ->Option.mapWithDefault([], topicFilters =>
      topicFilters
      ->(Utils.magic: Js.Json.t => unknown)
      ->normalizeOrThrow
      ->Js.Array2.map(encoder)
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

// ============== Build complete EVM event config ==============

let buildEvmEventConfig = (
  ~contractName: string,
  ~eventName: string,
  ~sighash: string,
  ~params: array<eventParam>,
  ~isWildcard: bool,
  ~handler: option<Internal.handler>,
  ~contractRegister: option<Internal.contractRegister>,
  ~eventFilters: option<Js.Json.t>,
  ~blockFields: option<array<Internal.evmBlockField>>=?,
  ~transactionFields: option<array<Internal.evmTransactionField>>=?,
  ~globalBlockFieldsSet: Utils.Set.t<Internal.evmBlockField>=Utils.Set.make(),
  ~globalTransactionFieldsSet: Utils.Set.t<Internal.evmTransactionField>=Utils.Set.make(),
): Internal.evmEventConfig => {
  let topicCount = params->Array.reduce(1, (acc, p) => p.indexed ? acc + 1 : acc)
  let indexedParams = params->Js.Array2.filter(p => p.indexed)

  let {getEventFiltersOrThrow, filterByAddresses} = LogSelection.parseEventFiltersOrThrow(
    ~eventFilters,
    ~sighash,
    ~params=indexedParams->Array.map(p => p.name),
    ~topic1=?indexedParams->Array.get(0)->Option.map(buildTopicGetter),
    ~topic2=?indexedParams->Array.get(1)->Option.map(buildTopicGetter),
    ~topic3=?indexedParams->Array.get(2)->Option.map(buildTopicGetter),
  )

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
    dependsOnAddresses: !isWildcard || filterByAddresses,
    convertHyperSyncEventArgs: buildHyperSyncDecoder(params),
    selectedBlockFields,
    selectedTransactionFields,
  }
}

// ============== Build Fuel event config ==============

let buildFuelEventConfig = (
  ~contractName: string,
  ~eventName: string,
  ~kind: string,
  ~sighash: string,
  ~rawAbi: Js.Json.t,
  ~isWildcard: bool,
  ~handler: option<Internal.handler>,
  ~contractRegister: option<Internal.contractRegister>,
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
  | other => Js.Exn.raiseError(`Unsupported Fuel event kind: ${other}`)
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
    ->(Utils.magic: S.t<Js.Json.t> => S.t<Internal.eventParams>)
  | other => Js.Exn.raiseError(`Unsupported Fuel event kind: ${other}`)
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
    kind: fuelKind,
  }
}
