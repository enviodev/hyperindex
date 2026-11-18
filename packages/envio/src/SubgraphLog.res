// Every line the subgraph runtime logs, and every line a mapping logs through
// graph-ts (`uinfo`, `uwarn`, ...), as it is logged. A test indexer's own logger
// is silent, so this is how a test reads them. Compiled to JavaScript so a test
// can import it from an installed envio, where TypeScript isn't stripped.

type listener = (string, string) => unit

let listeners: array<listener> = []

let onLog = (listener: listener) => {
  listeners->Array.push(listener)
  () =>
    switch listeners->Array.indexOf(listener) {
    | -1 => ()
    | index => listeners->Array.splice(~start=index, ~remove=1, ~insert=[])
    }
}

let notify = (level, message) => listeners->Array.forEach(listener => listener(level, message))
