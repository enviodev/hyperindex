@genType
type t<'sync, 'async> = Sync('sync) | Async('async)

let isAsync = syncAsync =>
  switch syncAsync {
  | Sync(_) => false
  | Async(_) => true
  }
