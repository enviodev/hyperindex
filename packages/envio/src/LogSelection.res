// Expand a resolved topic selection into concrete topic values for a query:
// `ContractAddresses` markers become the given partition addresses encoded as
// topics; `Values` pass through.
let materializeTopicFilter = (filter: Internal.topicFilter, ~addresses: array<Address.t>) =>
  switch filter {
  | Values(values) => values
  | ContractAddresses(_) => addresses->Array.map(TopicFilter.fromAddress)
  }

let materializeTopicSelections = (
  topicSelections: array<Internal.resolvedTopicSelection>,
  ~addresses: array<Address.t>,
): array<Internal.topicSelection> =>
  topicSelections->Array.map(({topic0, topic1, topic2, topic3}): Internal.topicSelection => {
    topic0,
    topic1: topic1->materializeTopicFilter(~addresses),
    topic2: topic2->materializeTopicFilter(~addresses),
    topic3: topic3->materializeTopicFilter(~addresses),
  })

type parsedWhere = {
  resolvedWhere: Internal.resolvedWhere,
  filterByAddresses: bool,
  // Indexed params filtered by `chain.<Contract>.addresses`, in disjunctive
  // normal form (outer array OR of AND-groups). Empty unless `filterByAddresses`.
  // Consumed by the codegen of the event's `clientAddressFilter`.
  addressFilterParamGroups: array<array<string>>,
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

// Build the `chain` argument passed into a `where` callback.
// `chain.<ContractName>.addresses` is a getter so the runtime can tell
// whether the callback actually reads it; the contract sub-object itself is
// built via `defineProperty` only because its `addresses` field needs the
// getter — the enclosing chainObj is a plain JS object.
let makeChainArg = (
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

// Sentinel returned by `chain.<Contract>.addresses`. A Proxy
// whose traps throw on any access, so the only non-throwing use is passing it
// straight through as a param filter value — which `extractAddressFilterGroups`
// then finds by identity. Misuse (spread/map/index/...) fails loud at the site.
let makeAddressesProbe: (
  ~contractName: string,
) => array<Address.t> = %raw(`function (contractName) {
  var trap = function () {
    throw new Error(
      'Invalid where configuration for "' + contractName +
      '": chain.' + contractName + '.addresses must be passed directly as an indexed-param ' +
      'filter value (e.g. { params: { to: chain.' + contractName + '.addresses } }). ' +
      'It cannot be spread, mapped, indexed, or otherwise transformed.'
    );
  };
  return new Proxy([], {get: trap});
}`)

let parseWhereOrThrow = {
  let emptyTopics = []
  let noopGetter = _ => emptyTopics

  (
    ~where: option<JSON.t>,
    ~sighash,
    ~params: array<string>,
    ~contractName: string,
    ~chainId: int,
    ~onEventBlockFilterSchema: S.t<option<unknown>>,
    ~topic1=noopGetter,
    ~topic2=noopGetter,
    ~topic3=noopGetter,
  ): parsedWhere => {
    let addressFilterParamGroups = []
    let readAddresses = ref(false)
    let addressesSentinel = makeAddressesProbe(~contractName)
    let sentinelJson = addressesSentinel->(Utils.magic: array<Address.t> => JSON.t)
    let topic0 = [sighash->EvmTypes.Hex.fromStringUnsafe]
    let default = {
      Internal.topic0,
      topic1: Values(emptyTopics),
      topic2: Values(emptyTopics),
      topic3: Values(emptyTopics),
    }

    // Topic positions map 1:1 onto the event's indexed params in declared
    // order, so the sentinel check keys off `params[index]`. The sentinel must
    // be detected before the topic getter runs — the getter would otherwise
    // touch the throwing Proxy while encoding.
    let topicFilterAt = (paramsFilter: dict<JSON.t>, ~index, ~getter) =>
      switch params
      ->Array.get(index)
      ->Option.flatMap(name => paramsFilter->Utils.Dict.dangerouslyGetNonOption(name)) {
      | Some(value) if value === sentinelJson =>
        Internal.ContractAddresses({contractName: contractName})
      | _ => Values(getter(paramsFilter))
      }

    // Build a single topic selection from one indexed-param record (the
    // inside of `params`). Validates that the keys are actual indexed
    // parameters of the event — TS type checking doesn't catch this when
    // `where` is a callback.
    let paramsRecordToTopicSelection = (paramsFilter: dict<JSON.t>) => {
      if paramsFilter->Utils.Dict.isEmpty {
        default
      } else {
        let sentinelParamNames = []
        paramsFilter->Utils.Dict.forEachWithKey((value, key) => {
          if params->Array.includes(key)->not {
            JsError.throwWithMessage(
              `Invalid where configuration. The event doesn't have an indexed parameter "${key}" and can't use it for filtering`,
            )
          }
          if value === sentinelJson {
            sentinelParamNames->Array.push(key)->ignore
          }
        })
        if sentinelParamNames->Utils.Array.isEmpty->not {
          addressFilterParamGroups->Array.push(sentinelParamNames)->ignore
        }
        {
          Internal.topic0,
          topic1: paramsFilter->topicFilterAt(~index=0, ~getter=topic1),
          topic2: paramsFilter->topicFilterAt(~index=1, ~getter=topic2),
          topic3: paramsFilter->topicFilterAt(~index=2, ~getter=topic3),
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
    let parse = (where: JSON.t): array<Internal.resolvedTopicSelection> => {
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
            obj->Utils.Dict.forEachWithKey((_, key) => {
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

    // The callback is invoked exactly once per chain, at registration time,
    // with the chain's real configured id. `chain.<Contract>.addresses` yields
    // the throwing-Proxy sentinel, which the param parser turns into a
    // `ContractAddresses` marker; addresses are expanded from the marker only
    // when a source query is built.
    // A misused Proxy (or any throw from the callback) propagates as-is —
    // the Proxy's guidance message surfaces without wrapping.
    let (topicSelections, startBlock) = switch where {
    | None => ([default], None)
    | Some(where) =>
      let whereValue = if typeof(where) === #function {
        let fn = where->(Utils.magic: JSON.t => Internal.onEventWhereArgs<_> => JSON.t)
        let chain = makeChainArg(~contractName, ~chainId, ~getAddresses=() => {
          readAddresses := true
          addressesSentinel
        })
        fn({chain: chain->Obj.magic})
      } else {
        where
      }
      let topicSelections = whereValue->parse
      if readAddresses.contents && addressFilterParamGroups->Utils.Array.isEmpty {
        JsError.throwWithMessage(
          `Invalid where configuration for ${contractName}. The callback reads \`chain.${contractName}.addresses\` but doesn't use it as an indexed-param filter value. Use it directly, e.g. { params: { to: chain.${contractName}.addresses } }.`,
        )
      }
      (topicSelections, extractStartBlock(~onEventBlockFilterSchema, ~contractName, whereValue))
    }

    {
      resolvedWhere: {
        topicSelections,
        startBlock,
      },
      filterByAddresses: addressFilterParamGroups->Utils.Array.isEmpty->not,
      addressFilterParamGroups,
    }
  }
}
