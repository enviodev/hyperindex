type chain = {
  chainId: string,
  mutable eventsProcessed: option<int>,
  mutable progressBlock: option<int>,
  mutable bufferBlock: option<int>,
  mutable sourceBlock: option<int>,
  mutable poweredByHyperSync: bool,
  mutable startBlock: int,
  mutable endBlock: option<int>,
}

module Metrics = {
  type metric = {
    name: string,
    value: string,
    labels: option<dict<string>>,
  }

  type parsing = Comment | Name | LabelKey | LabelValue | Value

  let select = Utils.Set.fromArray([
    "envio_events_processed_count",
    "envio_progress_block_number",
    "envio_indexing_start_block",
    "envio_indexing_end_block",
    "envio_indexing_buffer_block_number",
    "envio_source_height",
  ])

  // Parses prometheus-style metrics data into an array of metric objects
  let parseMetrics = data => {
    let metrics = []

    // Track current metric being built
    let currentName = ref("")
    let currentValue = ref("")
    let currentLabels = ref(None)
    let parsing = ref(Name)
    let currentLabelKey = ref("")
    let currentLabelValue = ref("")

    // Parse character by character
    let idx = ref(0)
    let lastIdx = data->String.length - 1

    while idx.contents <= lastIdx {
      let char = data->Js.String2.charAt(idx.contents)
      idx := idx.contents + 1

      // On newline, push current metric if valid and reset state
      if char === "\n" {
        if currentName.contents !== "" && parsing.contents !== Comment {
          metrics
          ->Js.Array2.push({
            name: currentName.contents,
            value: currentValue.contents,
            labels: currentLabels.contents,
          })
          ->ignore
        }
        currentName := ""
        currentValue := ""
        currentLabels := None
        parsing := Name
      } else {
        switch parsing.contents {
        | Comment => () // Skip comments until new line
        | Name =>
          // Handle start of comment, value, labels or continue building name
          if char === "#" && currentName.contents === "" {
            parsing := Comment
          } else if char === " " {
            if select->Utils.Set.has(currentName.contents) {
              parsing := Value
            } else {
              parsing := Comment
            }
          } else if char === "{" {
            if select->Utils.Set.has(currentName.contents) {
              parsing := LabelKey
            } else {
              parsing := Comment
            }
          } else {
            currentName := currentName.contents ++ char
          }
        | LabelKey =>
          // Build label key until = is found
          if char === "=" {
            parsing := LabelValue
          } else {
            currentLabelKey := currentLabelKey.contents ++ char
          }
        | LabelValue =>
          // Build label value until } or , is found
          if char === "}" || char === "," {
            let labelsDict = switch currentLabels.contents {
            | Some(labels) => labels
            | None => {
                let d = Js.Dict.empty()
                currentLabels := Some(d)
                d
              }
            }
            labelsDict->Js.Dict.set(currentLabelKey.contents, currentLabelValue.contents)
            currentLabelKey := ""
            currentLabelValue := ""

            if char === "}" {
              parsing := Name
            } else {
              parsing := LabelKey
            }
          } else if char !== "\"" {
            currentLabelValue := currentLabelValue.contents ++ char
          }
        | Value => currentValue := currentValue.contents ++ char
        }
      }
    }

    metrics
  }

  let parseMetricsToChains = (metrics: array<metric>): array<chain> => {
    // Group metrics by chainId
    let chainsMap = Js.Dict.empty()

    metrics->Js.Array2.forEach(metric => {
      let labels = metric.labels->Belt.Option.getWithDefault(Js.Dict.empty())
      let chainId = labels->Js.Dict.get("chainId")->Belt.Option.getWithDefault("unknown")
      let value = metric.value->Belt.Int.fromString->Belt.Option.getWithDefault(0)

      // Get or create chain entry
      let chain = switch chainsMap->Js.Dict.get(chainId) {
      | Some(existingChain) => existingChain
      | None => {
          let newChain = {
            chainId,
            eventsProcessed: None,
            progressBlock: None,
            bufferBlock: None,
            sourceBlock: None,
            poweredByHyperSync: false,
            startBlock: 0,
            endBlock: None,
          }
          chainsMap->Js.Dict.set(chainId, newChain)
          newChain
        }
      }

      // Update the appropriate field based on metric name
      switch metric.name {
      | "envio_events_processed_count" => chain.eventsProcessed = Some(value)
      | "envio_progress_block_number" => chain.progressBlock = Some(value)
      | "envio_indexing_buffer_block_number" => chain.bufferBlock = Some(value)
      | "envio_indexing_start_block" => chain.startBlock = value
      | "envio_indexing_end_block" => chain.endBlock = Some(value)
      | "envio_source_height" =>
        if (
          switch chain.sourceBlock {
          | Some(existingValue) => existingValue < value
          | None => true
          }
        ) {
          chain.sourceBlock = Some(value)
          if labels->Js.Dict.get("source") === Some("HyperSync") {
            chain.poweredByHyperSync = true
          }
        }
      | _ => ()
      }
    })

    // Convert map values to array
    chainsMap->Js.Dict.values
  }
}

type number
@val external number: int => number = "Number"
@send external toLocaleString: number => string = "toLocaleString"
let formatLocaleString = n => n->number->toLocaleString
