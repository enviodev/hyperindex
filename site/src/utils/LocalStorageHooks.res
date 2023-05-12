type key = Theme

let keyToString = key =>
  switch key {
  | Theme => "theme"
  }

let useLocalStorageStateAtKey = (~key: key) => {
  let (state, setState) = React.useState(_ => None)

  let keyString = key->keyToString

  React.useEffect0(() => {
    let item = Dom.Storage2.localStorage->Dom.Storage2.getItem(keyString)
    setState(_ => item)

    None
  })

  let setStorage = item => {
    Dom.Storage2.localStorage->Dom.Storage2.setItem(keyString, item)
    setState(_ => Some(item))
  }

  (state, setStorage)
}
