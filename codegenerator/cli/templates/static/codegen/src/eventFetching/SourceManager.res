// Ideally the ChainFetcher name suits this better
// But currently the ChainFetcher module is immutable
// and handles both processing and fetching.
// So this module is to encapsulate the fetching logic only
// with a mutable state for easier reasoning and testing.
type t = {
  chainConfig: Config.chainConfig,
  mutable isWaitingForNewBlock: bool,
}

let make = (~chainConfig) => {
  chainConfig,
  isWaitingForNewBlock: false,
}
