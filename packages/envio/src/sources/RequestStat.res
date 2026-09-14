// A single backend request a source method made, with the time it took. Kept
// in its own leaf module (rather than on `Source`) so the client FFI bindings
// can name it without importing `Source` — which would form a dependency cycle
// through `Env → HyperSyncClient → Source → FetchState → Env`.
type t = {
  method: string,
  seconds: float,
  // Blocks the backend returned for this request, before any client-side
  // routing drops them. Absent for methods whose responses aren't measured in
  // blocks, so a zero always means the request came back empty.
  responseBlocks?: int,
}
