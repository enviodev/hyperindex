exception MissingRequiredTopic0
let makeTopicSelection = (~topic0, ~topic1=[], ~topic2=[], ~topic3=[]) =>
  if topic0->Utils.Array.isEmpty {
    Error(MissingRequiredTopic0)
  } else {
    {
      Internal.topic0,
      topic1,
      topic2,
      topic3,
    }->Ok
  }

let hasFilters = ({topic1, topic2, topic3}: Internal.topicSelection) => {
  [topic1, topic2, topic3]->Js.Array2.find(topic => !Utils.Array.isEmpty(topic))->Belt.Option.isSome
}

/**
For a group of topic selections, if multiple only use topic0, then they can be compressed into one
selection combining the topic0s
*/
let compressTopicSelections = (topicSelections: array<Internal.topicSelection>) => {
  let topic0sOfSelectionsWithoutFilters = []

  let selectionsWithFilters = []

  topicSelections->Belt.Array.forEach(selection => {
    if selection->hasFilters {
      selectionsWithFilters->Js.Array2.push(selection)->ignore
    } else {
      selection.topic0->Belt.Array.forEach(topic0 => {
        topic0sOfSelectionsWithoutFilters->Js.Array2.push(topic0)->ignore
      })
    }
  })

  switch topic0sOfSelectionsWithoutFilters {
  | [] => selectionsWithFilters
  | topic0 =>
    let selectionWithoutFilters = {
      Internal.topic0,
      topic1: [],
      topic2: [],
      topic3: [],
    }
    Belt.Array.concat([selectionWithoutFilters], selectionsWithFilters)
  }
}

type t = {
  addresses: array<Address.t>,
  topicSelections: array<Internal.topicSelection>,
}

let make = (~addresses, ~topicSelections) => {
  let topicSelections = compressTopicSelections(topicSelections)
  {addresses, topicSelections}
}

type parsedEventFilters = {
  getEventFiltersOrThrow: ChainMap.Chain.t => Internal.eventFilters,
  filterByAddresses: bool,
}

// Build the runtime `chain` argument passed into a `where` callback.
// Exposes `chain.id` and `chain.<ContractName>.addresses` as plain values
// on a normal (Object.prototype) JS object. `Js.Dict` is used so the
// contract name can be a dynamic property key without defineProperty
// ceremony.
let makeChainArg = (~contractName: string, ~chainId: int, ~addresses: array<Address.t>) => {
  let chainObj = Js.Dict.empty()
  chainObj->Js.Dict.set("id", chainId->Obj.magic)
  chainObj->Js.Dict.set(contractName, {"addresses": addresses}->Obj.magic)
  chainObj
}

// Build the detection-time `chain` argument. `chain.<ContractName>.addresses`
// is a getter so the runtime can tell whether the callback actually reads
// it; the contract sub-object itself is built via `defineProperty` only
// because its `addresses` field needs the getter — the enclosing chainObj
// is a plain JS object.
let makeDetectionChainArg = (
  ~contractName: string,
  ~chainId: int,
  ~getAddresses: unit => array<Address.t>,
) => {
  let contractObj = Utils.Object.createNullObject()
  contractObj
  ->Utils.Object.defineProperty("addresses", {enumerable: true, get: getAddresses})
  ->ignore
  let chainObj = Js.Dict.empty()
  chainObj->Js.Dict.set("id", chainId->Obj.magic)
  chainObj->Js.Dict.set(contractName, contractObj->Obj.magic)
  chainObj
}

let parseEventFiltersOrThrow = {
  let emptyTopics = []
  let noopGetter = _ => emptyTopics

  (
    ~eventFilters: option<Js.Json.t>,
    ~sighash,
    ~params,
    ~contractName: string,
    ~probeChainId: int,
    ~topic1=noopGetter,
    ~topic2=noopGetter,
    ~topic3=noopGetter,
  ): parsedEventFilters => {
    let filterByAddresses = ref(false)
    let topic0 = [sighash->EvmTypes.Hex.fromStringUnsafe]
    let default = {
      Internal.topic0,
      topic1: emptyTopics,
      topic2: emptyTopics,
      topic3: emptyTopics,
    }

    // Build a single topic selection from one indexed-param record (the
    // inside of `params`). Validates that the keys are actual indexed
    // parameters of the event — TS type checking doesn't catch this when
    // `where` is a callback.
    let paramsRecordToTopicSelection = (paramsFilter: Js.Dict.t<Js.Json.t>) => {
      let filterKeys = paramsFilter->Js.Dict.keys
      switch filterKeys {
      | [] => default
      | _ => {
          filterKeys->Js.Array2.forEach(key => {
            if params->Js.Array2.includes(key)->not {
              Js.Exn.raiseError(
                `Invalid where configuration. The event doesn't have an indexed parameter "${key}" and can't use it for filtering`,
              )
            }
          })
          {
            Internal.topic0,
            topic1: topic1(paramsFilter),
            topic2: topic2(paramsFilter),
            topic3: topic3(paramsFilter),
          }
        }
      }
    }

    // Parse a `where` value (or the result of calling the dynamic callback)
    // into a list of topic selections.
    //
    // Accepted shapes:
    // - `true`  → KeepAll → match the event signature with no narrowing
    // - `false` → SkipAll → no events
    // - `{}` (or `{params: undefined}`) → no narrowing
    // - `{params: {...}}` → single AND-conjunction
    // - `{params: [{...}, {...}]}` → OR of multiple AND-conjunctions
    //
    // The runtime accepts both the function form (the only form ReScript
    // exposes) and a top-level static object form (TypeScript convenience).
    let parse = (where: Js.Json.t): array<Internal.topicSelection> => {
      if where === Obj.magic(true) {
        [default]
      } else if where === Obj.magic(false) {
        []
      } else {
        // A `where` condition is shaped as `{params?: ..., ...}` where
        // `params` carries the indexed-parameter filter record. Future
        // filter dimensions (block, transaction, …) can slot in as sibling
        // fields alongside `params`.
        switch where {
        | Object(obj) =>
          switch obj->Js.Dict.get("params") {
          | None =>
            // Reject non-empty objects without `params` — almost always a
            // typo (e.g. `parmas:`) or the legacy flat-filter shape
            // (`{from: ...}`). Empty `{}` is fine and means "match all".
            if obj->Js.Dict.keys->Js.Array2.length > 0 {
              Js.Exn.raiseError(
                "Invalid where configuration. Indexed parameter filters must be nested under `params`",
              )
            } else {
              [default]
            }
          | Some(Object(p)) => [paramsRecordToTopicSelection(p)]
          | Some(Array([])) => [default]
          | Some(Array(arr)) =>
            arr->Js.Array2.map(item =>
              switch item {
              | Object(p) => paramsRecordToTopicSelection(p)
              | _ =>
                Js.Exn.raiseError(
                  "Invalid where configuration. Each entry in `params` must be an object",
                )
              }
            )
          | Some(_) =>
            Js.Exn.raiseError(
              "Invalid where configuration. Expected `params` to be an object or an array of objects",
            )
          }
        | _ => Js.Exn.raiseError("Invalid where configuration. Expected an object")
        }
      }
    }

    let getEventFiltersOrThrow = switch eventFilters {
    | None => {
        let static: Internal.eventFilters = Static([default])
        _ => static
      }
    | Some(eventFilters) =>
      if Js.typeof(eventFilters) === "function" {
        let fn = eventFilters->(Utils.magic: Js.Json.t => Internal.onEventWhereArgs<_> => Js.Json.t)
        // Determine whether the callback uses addresses by probing it with
        // a detection chain arg whose `chain.<ContractName>.addresses` getter
        // flips a flag. The probe uses this chain's real configured id, so
        // handlers that branch on `chain.id` are exercised along the path
        // they take for this chain. Event configs are built per-chain, so
        // each chain gets a `filterByAddresses` verdict that matches its
        // own callback behaviour.
        try {
          let chain = makeDetectionChainArg(
            ~contractName,
            ~chainId=probeChainId,
            ~getAddresses=() => {
              filterByAddresses := true
              []
            },
          )
          let _ = fn({chain: chain->Obj.magic})
        } catch {
        | _ => ()
        }
        if filterByAddresses.contents {
          chain => Internal.Dynamic(
            addresses => {
              let chainArg = makeChainArg(
                ~contractName,
                ~chainId=chain->ChainMap.Chain.toChainId,
                ~addresses,
              )
              fn({chain: chainArg->Obj.magic})->parse
            },
          )
        } else {
          // No probed chain referenced the contract — cache as Static
          // per chain to avoid recomputing topic selections each batch.
          // The addresses getter throws: if a code path the probe didn't
          // exercise reads `chain.<Contract>.addresses` at runtime, silent
          // [] would produce wrong topics — throw a user-friendly error
          // instead so the user rewrites the callback to surface the
          // dependency up-front.
          chain => {
            let chainId = chain->ChainMap.Chain.toChainId
            let chainArg = makeDetectionChainArg(~contractName, ~chainId, ~getAddresses=() =>
              Js.Exn.raiseError(
                `Invalid where configuration. Event callback for contract "${contractName}" read \`chain.${contractName}.addresses\` at runtime but the probe didn't detect the access on chainId ${chainId->Belt.Int.toString}. Move the \`chain.${contractName}.addresses\` read above any \`chain.id\` branching so the probe picks up the dependency and switches to the dynamic fetch path.`,
              )
            )
            Internal.Static(fn({chain: chainArg->Obj.magic})->parse)
          }
        }
      } else {
        let static: Internal.eventFilters = Static(eventFilters->parse)
        _ => static
      }
    }

    {
      getEventFiltersOrThrow,
      filterByAddresses: filterByAddresses.contents,
    }
  }
}
