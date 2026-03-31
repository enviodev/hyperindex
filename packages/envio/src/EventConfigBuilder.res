open Belt

type eventParam = {
  name: string,
  abiType: string,
  indexed: bool,
}

let eventParamSchema = S.object(s => {
  name: s.field("name", S.string),
  abiType: s.field("abiType", S.string),
  indexed: s.fieldOr("indexed", S.bool, false),
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
    | t if t->Js.String2.startsWith("uint") => BigInt.schema->S.toUnknown
    | t if t->Js.String2.startsWith("int") => BigInt.schema->S.toUnknown
    | t if t->Js.String2.startsWith("bytes") => S.string->S.toUnknown
    | other => Js.Exn.raiseError(`Unsupported ABI type: ${other}`)
    }
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

// ============== Build HyperSync decoder via new Function() ==============

// new Function(arg1, arg2, body) - creates a function at runtime
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

    // Generate function body:
    // "return { from: t(d.indexed[0]), to: t(d.indexed[1]), value: t(d.body[0]) }"
    let fields = []
    indexedParams->Array.forEachWithIndex((i, p) => {
      fields->Js.Array2.push(`"${p.name}": t(d.indexed[${i->Int.toString}])`)->ignore
    })
    bodyParams->Array.forEachWithIndex((i, p) => {
      fields->Js.Array2.push(`"${p.name}": t(d.body[${i->Int.toString}])`)->ignore
    })
    let body = `return {${fields->Js.Array2.joinWith(", ")}}`

    let factory: (
      HyperSyncClient.Decoder.decodedRaw => HyperSyncClient.Decoder.decodedUnderlying
    ) => HyperSyncClient.Decoder.decodedEvent => Internal.eventParams =
      makeFunction(["t", "d", body])->Utils.magic

    factory(HyperSyncClient.Decoder.toUnderlying)
  }
}

// ============== Build topic filter getters ==============

let getTopicEncoder = (abiType: string): (unknown => EvmTypes.Hex.t) => {
  // Handle array/tuple types - these get keccak256'd
  if abiType->Js.String2.endsWith("]") || abiType->Js.String2.startsWith("(") {
    TopicFilter.castToHexUnsafe->Utils.magic
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
      ->Obj.magic
      ->normalizeOrThrow
      ->Array.map(encoder)
    )
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
  {
    id: sighash ++ "_" ++ topicCount->Int.toString,
    name: eventName,
    contractName,
    isWildcard,
    handler,
    contractRegister,
    paramsRawEventSchema: buildParamsSchema(params),
    getEventFiltersOrThrow,
    filterByAddresses,
    dependsOnAddresses: !isWildcard || filterByAddresses,
    convertHyperSyncEventArgs: buildHyperSyncDecoder(params),
    selectedBlockFields: Utils.Set.make(),
    selectedTransactionFields: Utils.Set.make(),
  }
}

// ============== Build Fuel event config ==============

let buildFuelEventConfig = (
  ~contractName: string,
  ~eventName: string,
  ~kind: string,
  ~sighash: string,
  ~abi: EvmTypes.Abi.t,
  ~isWildcard: bool,
  ~handler: option<Internal.handler>,
  ~contractRegister: option<Internal.contractRegister>,
): Internal.fuelEventConfig => {
  let fuelKind = switch kind {
  | "logData" =>
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
    filterByAddresses: false,
    dependsOnAddresses: !isWildcard,
    kind: fuelKind,
  }
}
