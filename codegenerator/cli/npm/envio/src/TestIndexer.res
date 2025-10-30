type chainOptions = {startBlock?: int}

type options = {
  chains?: dict<chainOptions>,
  entities?: dict<array<unknown>>,
}

type rec t = {progress: dict<int> => promise<t>, snapshot: unit => promise<unit>}

let factory = (~config as _: Config.t) => {
  () => ()
}
