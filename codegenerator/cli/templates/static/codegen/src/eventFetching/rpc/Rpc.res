type hex = string
@unboxed
type topicFilter = Single(hex) | Multiple(array<hex>) | @as(undefined) Undefined
type topicQuery = array<topicFilter>
let makeTopicQuery = (~topic0=[], ~topic1=[], ~topic2=[], ~topic3=[]) => {
  let topics = [topic0, topic1, topic2, topic3]

  let isLastTopicEmpty = () =>
    switch topics->Utils.Array.last {
    | Some([]) => true
    | _ => false
    }

  //Remove all empty topics from the end of the array
  while isLastTopicEmpty() {
    topics->Js.Array2.pop->ignore
  }

  let toTopicFilter = topic => {
    switch topic {
    | [] => Undefined
    | [single] => Single(single->EvmTypes.Hex.toString)
    | multiple => Multiple(multiple->EvmTypes.Hex.toStrings)
    }
  }

  topics->Belt.Array.map(toTopicFilter)
}

let mapTopicQuery = ({topic0, topic1, topic2, topic3}: LogSelection.topicSelection): topicQuery =>
  makeTopicQuery(~topic0, ~topic1, ~topic2, ~topic3)
