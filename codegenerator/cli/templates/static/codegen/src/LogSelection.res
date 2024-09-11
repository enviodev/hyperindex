type topicSelection = {
  topic0: array<EvmTypes.Hex.t>,
  topic1: array<EvmTypes.Hex.t>,
  topic2: array<EvmTypes.Hex.t>,
  topic3: array<EvmTypes.Hex.t>,
}

exception MissingRequiredTopic0
let makeTopicSelection = (~topic0, ~topic1=[], ~topic2=[], ~topic3=[]) =>
  if topic0->Utils.Array.isEmpty {
    Error(MissingRequiredTopic0)
  } else {
    {
      topic0,
      topic1,
      topic2,
      topic3,
    }->Ok
  }

let hasFilters = ({topic1, topic2, topic3}: topicSelection) => {
  [topic1, topic2, topic3]->Js.Array2.find(topic => !Utils.Array.isEmpty(topic))->Belt.Option.isSome
}

type t = {
  addresses: array<Address.t>,
  topicSelections: array<topicSelection>,
}

let make = (~addresses, ~topicSelections) => {addresses, topicSelections}
