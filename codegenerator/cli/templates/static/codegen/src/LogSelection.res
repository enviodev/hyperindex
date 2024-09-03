open Belt
type hex = EvmTypes.Hex.t
type topicSelection = {
  topic0: array<hex>,
  topic1: array<hex>,
  topic2: array<hex>,
  topic3: array<hex>,
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

let topicSelectionsHaveFilters = (topicSelections: array<topicSelection>) =>
  topicSelections->Array.some(topicSelectionHasFilters)

let hasTopicFilters = ({topicSelections}: t) => topicSelections->topicSelectionsHaveFilters

type topicFilter = array<EvmTypes.Hex.t>
type topicQuery = (topicFilter, topicFilter, topicFilter, topicFilter)
let makeTopicQuery = (~topic0=[], ~topic1=[], ~topic2=[], ~topic3=[]) => (
  topic0,
  topic1,
  topic2,
  topic3,
)

let mapTopicQuery = ({topic0, topic1, topic2, topic3}: topicSelection): topicQuery =>
  makeTopicQuery(~topic0, ~topic1, ~topic2, ~topic3)
