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

let fromEventFiltersOrThrow = {
  let emptyTopics = []
  let noopGetter = _ => emptyTopics

  (
    ~chain,
    ~eventFilters: option<Js.Json.t>,
    ~sighash,
    ~topic1=noopGetter,
    ~topic2=noopGetter,
    ~topic3=noopGetter,
  ) => {
    let topic0 = [sighash->EvmTypes.Hex.fromStringUnsafe]
    switch eventFilters {
    | None => [
        {
          Internal.topic0,
          topic1: emptyTopics,
          topic2: emptyTopics,
          topic3: emptyTopics,
        },
      ]
    | Some(eventFilters) => {
        let eventFilters = if Js.typeof(eventFilters) === "function" {
          (eventFilters->(Utils.magic: Js.Json.t => Internal.eventFiltersArgs => Js.Json.t))({
            chainId: chain->ChainMap.Chain.toChainId,
          })
        } else {
          eventFilters
        }

        switch eventFilters {
        | Array([]) => [%raw(`{}`)]
        | Array(a) => a
        | _ => [eventFilters]
        }->Js.Array2.map(eventFilter => {
          switch eventFilter {
          | Object(eventFilter) => {
              Internal.topic0,
              topic1: topic1(eventFilter),
              topic2: topic2(eventFilter),
              topic3: topic3(eventFilter),
            }
          | _ => Js.Exn.raiseError("Invalid event filters configuration. Expected an object")
          }
        })
      }
    }
  }
}
