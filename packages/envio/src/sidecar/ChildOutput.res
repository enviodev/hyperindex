// A child of `envio dev` writing to the terminal directly would tear the TUI
// frame, so its output goes through console a line at a time, labelled.
let pipeLines = (stream: Null.t<NodeJs.ChildProcess.Stream.t>, ~label, ~print) =>
  switch stream->Null.toOption {
  | None => ()
  | Some(stream) =>
    stream->NodeJs.ChildProcess.Stream.setEncoding("utf8")
    let pending = ref("")
    stream->NodeJs.ChildProcess.Stream.onData(chunk => {
      let lines = (pending.contents ++ chunk)->String.split("\n")
      pending := lines->Array.pop->Option.getOr("")
      lines->Array.forEach(line => print(`[${label}] ${line}`))
    })
    stream->NodeJs.ChildProcess.Stream.onEnd(() =>
      if pending.contents !== "" {
        print(`[${label}] ${pending.contents}`)
      }
    )
  }
