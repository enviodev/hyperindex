let useLocalStorageStateAtKey = (~key) => {
  let (state, setState) = React.useState(_ => None)

  React.useEffect0(() => {
    let item = Dom.Storage2.localStorage->Dom.Storage2.getItem(key)
    setState(_ => item)

    None
  })

  let setStorage = item => {
    Dom.Storage2.localStorage->Dom.Storage2.setItem(key, item)
    setState(_ => Some(item))
  }

  (state, setStorage)
}
