type hexString = string
type topicSelection = {
  topic0: array<hexString>,
  topic1: array<hexString>,
  topic2: array<hexString>,
  topic3: array<hexString>,
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

type t = {
  addresses: array<Address.t>,
  topicSelections: array<topicSelection>,
}

let make = (~addresses, ~topicSelections) => {addresses, topicSelections}

let isWildCard = ({addresses}: t) => addresses->Utils.Array.isEmpty

let topicSelectionHasFilters = (topicSelection: topicSelection) =>
  switch topicSelection {
  | {topic1: [], topic2: [], topic3: []} => false
  | _ => true
  }

let hasTopicFilters = ({topicSelections}: t) =>
  topicSelections->Belt.Array.reduce(false, (accum, item) => {
    accum || item->topicSelectionHasFilters
  })
