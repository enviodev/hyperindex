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
  [topic1, topic2, topic3]->Array.find(topic => !Utils.Array.isEmpty(topic))->Belt.Option.isSome
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
      selectionsWithFilters->Array.push(selection)->ignore
    } else {
      selection.topic0->Belt.Array.forEach(topic0 => {
        topic0sOfSelectionsWithoutFilters->Array.push(topic0)->ignore
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
  // `_gte` from the top-level `block` filter of the user's `where`,
  // resolved at build time (per-chain via the `probeChainId`). The
  // caller uses this to override the per-event `startBlock` — a
  // `where`-derived startBlock always wins over contract-level
  // config, so users can widen or narrow individual event ranges
  // without touching `config.yaml`.
  startBlock: option<int>,
}

// Inner schema for the event `block` filter chunk: `{_gte?}`.
// `S.strict` rejects `_lte` / `_every` — those are stride/range concepts
// that only make sense for `onBlock` handlers, not event filters. Typos
// like `_gt` surface through the same strict-schema error path.
type eventBlockRange = {_gte: option<int>}
let eventBlockRangeSchema: S.t<eventBlockRange> = S.object(s => {
  _gte: s.field("_gte", S.option(S.int)),
})->S.strict

// Extract the per-event `startBlock` from a `where` result (or static
// value). Two-stage parse mirroring `onBlock`: the ecosystem schema
// strips the outer `block.number` / `block.height` wrapper, then
// `eventBlockRangeSchema` validates `{_gte?}` strictly — `_lte` and
// `_every` are rejected with a user-friendly message pointing users
// at `onBlock` for stride/endBlock semantics.
//
// Returns `None` for boolean `where` results, missing `block`, and
// `block.number: {}` (no `_gte`). Wraps schema errors with the
// contract/event context so the call-site is obvious in the log.
let extractStartBlock = (
  where: JSON.t,
  ~onEventBlockFilterSchema: S.t<option<unknown>>,
  ~contractName: string,
): option<int> => {
  // `where` may be a bool at runtime even though the static type is
  // `JSON.t` — the user callbacks can return `true`/`false` to keep/skip
  // a chain, and the value reaches here unwrapped. Detect with
  // `typeof` instead of an identity-equal check so ReScript doesn't
  // constant-fold the comparison away for the `JSON.t` nominal type.
  if typeof(where) === #boolean {
    None
  } else {
    try {
      switch where->S.parseOrThrow(onEventBlockFilterSchema) {
      | None => None
      | Some(inner) => (inner->S.parseOrThrow(eventBlockRangeSchema))._gte
      }
    } catch {
    | S.Raised(exn) =>
      JsError.throwWithMessage(
        `Invalid where configuration for ${contractName}. \`block\` filter is invalid: ${exn
          ->Utils.prettifyExn
          ->(
            Utils.magic: exn => string
          )}. Only \`_gte\` is supported on event filters — use \`indexer.onBlock\` for \`_lte\` or \`_every\`.`,
      )
    }
  }
}

// Build the runtime `chain` argument passed into a `where` callback.
// Exposes `chain.id` and `chain.<ContractName>.addresses` as plain values
// on a normal (Object.prototype) JS object. `Dict` is used so the
// contract name can be a dynamic property key without defineProperty
// ceremony.
let makeChainArg = (~contractName: string, ~chainId: int, ~addresses: array<Address.t>) => {
  let chainObj = Dict.make()
  chainObj->Dict.set("id", chainId->Obj.magic)
  chainObj->Dict.set(contractName, {"addresses": addresses}->Obj.magic)
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
  let chainObj = Dict.make()
  chainObj->Dict.set("id", chainId->Obj.magic)
  chainObj->Dict.set(contractName, contractObj->Obj.magic)
  chainObj
}

let parseEventFiltersOrThrow = {
  let emptyTopics = []
  let noopGetter = _ => emptyTopics

  (
    ~eventFilters: option<JSON.t>,
    ~sighash,
    ~params,
    ~contractName: string,
    ~probeChainId: int,
    ~onEventBlockFilterSchema: S.t<option<unknown>>,
    ~topic1=noopGetter,
    ~topic2=noopGetter,
    ~topic3=noopGetter,
  ): parsedEventFilters => {
    let filterByAddresses = ref(false)
    let startBlock = ref(None)
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
    let paramsRecordToTopicSelection = (paramsFilter: dict<JSON.t>) => {
      let filterKeys = paramsFilter->Dict.keysToArray
      switch filterKeys {
      | [] => default
      | _ => {
          filterKeys->Array.forEach(key => {
            if params->Array.includes(key)->not {
              JsError.throwWithMessage(
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

    // Known top-level `where` keys. `block` is a sibling of `params` — its
    // `_gte` promotes to the event's `startBlock` (extracted separately
    // by `extractStartBlock`). Unknown keys are rejected to catch typos
    // like `parmas` or `blocks` at registration time.
    let acceptedWhereKeys = ["params", "block"]

    // Parse a `where` value (or the result of calling the dynamic callback)
    // into a list of topic selections.
    //
    // Accepted shapes:
    // - `true`  → KeepAll → match the event signature with no narrowing
    // - `false` → SkipAll → no events
    // - `{}` (or `{params: undefined}`) → no narrowing
    // - `{params: {...}}` → single AND-conjunction
    // - `{params: [{...}, {...}]}` → OR of multiple AND-conjunctions
    // - `{block: {number: {_gte: N}}}` → no topic narrowing; startBlock only
    // - `{params: ..., block: ...}` → combined
    //
    // The runtime accepts both the function form (the only form ReScript
    // exposes) and a top-level static object form (TypeScript convenience).
    let parse = (where: JSON.t): array<Internal.topicSelection> => {
      if where === Obj.magic(true) {
        [default]
      } else if where === Obj.magic(false) {
        []
      } else {
        // A `where` condition is shaped as `{params?: ..., block?: ...}`.
        // `params` carries the indexed-parameter filter record; `block`
        // carries the per-event block-range filter handled by
        // `extractStartBlock`.
        switch where {
        | Object(obj) => {
            // Catch typos (e.g. `parmas:`) and the legacy flat-filter
            // shape (`{from: ...}`) by rejecting any unknown sibling.
            obj
            ->Dict.keysToArray
            ->Array.forEach(key => {
              if acceptedWhereKeys->Array.includes(key)->not {
                JsError.throwWithMessage(
                  `Invalid where configuration. Unknown field "${key}". Indexed parameter filters must be nested under \`params\` and block-range filters under \`block\``,
                )
              }
            })
            switch obj->Dict.get("params") {
            | None => [default]
            | Some(Object(p)) => [paramsRecordToTopicSelection(p)]
            | Some(Array([])) => [default]
            | Some(Array(arr)) =>
              arr->Array.map(item =>
                switch item {
                | Object(p) => paramsRecordToTopicSelection(p)
                | _ =>
                  JsError.throwWithMessage(
                    "Invalid where configuration. Each entry in `params` must be an object",
                  )
                }
              )
            | Some(_) =>
              JsError.throwWithMessage(
                "Invalid where configuration. Expected `params` to be an object or an array of objects",
              )
            }
          }
        | _ => JsError.throwWithMessage("Invalid where configuration. Expected an object")
        }
      }
    }

    let getEventFiltersOrThrow = switch eventFilters {
    | None => {
        let static: Internal.eventFilters = Static([default])
        _ => static
      }
    | Some(eventFilters) =>
      if typeof(eventFilters) === #function {
        let fn = eventFilters->(Utils.magic: JSON.t => Internal.onEventWhereArgs<_> => JSON.t)
        // Determine whether the callback uses addresses by probing it with
        // a detection chain arg whose `chain.<ContractName>.addresses` getter
        // flips a flag. The probe uses this chain's real configured id, so
        // handlers that branch on `chain.id` are exercised along the path
        // they take for this chain. Event configs are built per-chain, so
        // each chain gets a `filterByAddresses` verdict that matches its
        // own callback behaviour.
        //
        // The probe result is also reused to extract the per-event
        // `startBlock` (from `where.block`) for this chain — a second
        // invocation would risk observing different state for callbacks
        // that close over mutable references.
        let probedResult = try {
          let chain = makeDetectionChainArg(
            ~contractName,
            ~chainId=probeChainId,
            ~getAddresses=() => {
              filterByAddresses := true
              []
            },
          )
          Some(fn({chain: chain->Obj.magic}))
        } catch {
        | _ => None
        }
        switch probedResult {
        | Some(result) =>
          startBlock := extractStartBlock(~onEventBlockFilterSchema, ~contractName, result)
        | None => ()
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
              JsError.throwWithMessage(
                `Invalid where configuration. Event callback for contract "${contractName}" read \`chain.${contractName}.addresses\` at runtime but the probe didn't detect the access on chainId ${chainId->Int.toString}. Move the \`chain.${contractName}.addresses\` read above any \`chain.id\` branching so the probe picks up the dependency and switches to the dynamic fetch path.`,
              )
            )
            Internal.Static(fn({chain: chainArg->Obj.magic})->parse)
          }
        }
      } else {
        startBlock := extractStartBlock(~onEventBlockFilterSchema, ~contractName, eventFilters)
        let static: Internal.eventFilters = Static(eventFilters->parse)
        _ => static
      }
    }

    {
      getEventFiltersOrThrow,
      filterByAddresses: filterByAddresses.contents,
      startBlock: startBlock.contents,
    }
  }
}
