 module NodeFetch = {
  type t
  @module external fetch: t = "node-fetch"
  // https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/globalThis
  @val external globalThis: 'a = "globalThis"

  // Now it will use node-fetch polyfill globally.
  globalThis["fetch"] = fetch

  include Fetch
}

