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

let parseEventFiltersOrThrow = {
  let emptyTopics = []
  let noopGetter = _ => emptyTopics

  (
    ~eventFilters: option<Js.Json.t>,
    ~sighash,
    ~params,
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

    let parse = (eventFilters: Js.Json.t): array<Internal.topicSelection> => {
      switch eventFilters {
      | Array([]) => [%raw(`{}`)]
      | Array(a) => a
      | _ => [eventFilters]
      }->Js.Array2.map(eventFilter => {
        switch eventFilter {
        | Object(eventFilter) => {
            let filterKeys = eventFilter->Js.Dict.keys
            switch filterKeys {
            | [] => default
            | _ => {
                filterKeys->Js.Array2.forEach(key => {
                  if params->Js.Array2.includes(key)->not {
                    // In TS type validation doesn't catch this
                    // when we have eventFilters as a callback
                    Js.Exn.raiseError(
                      `Invalid event filters configuration. The event doesn't have an indexed parameter "${key}" and can't use it for filtering`,
                    )
                  }
                })
                {
                  Internal.topic0,
                  topic1: topic1(eventFilter),
                  topic2: topic2(eventFilter),
                  topic3: topic3(eventFilter),
                }
              }
            }
          }
        | _ => Js.Exn.raiseError("Invalid event filters configuration. Expected an object")
        }
      })
    }

    let getEventFiltersOrThrow = switch eventFilters {
    | None => {
        let static: Internal.eventFilters = Static([default])
        _ => static
      }
    | Some(eventFilters) =>
      if Js.typeof(eventFilters) === "function" {
        let fn = eventFilters->(Utils.magic: Js.Json.t => Internal.eventFiltersArgs => Js.Json.t)
        // When user passess a function to event filters we need to
        // first determine whether it uses addresses or not
        // Because the fetching logic will be different for wildcard events
        // 1. If wildcard event doesn't use addresses,
        //    it should start fetching even without static addresses in the config
        // 2. If wildcard event uses addresses in event filters,
        //    it should first wait for dynamic contract registration
        // So to deterimine which case we run the function with dummy args
        // and check if it uses addresses by using the getter.
        try {
          let args = (
            {
              chainId: 0,
              addresses: [],
            }: Internal.eventFiltersArgs
          )->Utils.Object.defineProperty(
            "addresses",
            {
              get: () => {
                filterByAddresses := true
                []
              },
            },
          )
          let _ = fn(args)
        } catch {
        | _ => ()
        }
        if filterByAddresses.contents {
          chain => Internal.Dynamic(
            addresses => fn({chainId: chain->ChainMap.Chain.toChainId, addresses})->parse,
          )
        } else {
          // When we don't depend on addresses, can mark the event filter
          // as static and avoid recalculating on every batch
          chain => Internal.Static(
            fn({chainId: chain->ChainMap.Chain.toChainId, addresses: []})->parse,
          )
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
