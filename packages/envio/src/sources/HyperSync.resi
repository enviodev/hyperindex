type logsQueryPage = {
  items: array<HyperSyncClient.EventItems.item>,
  nextBlock: int,
  archiveHeight: int,
  transactionStore: TransactionStore.t,
  blockStore: BlockStore.t,
}

// How often a HyperSync source is asked for the height while nothing is pushing
// one. Every ecosystem's client talks to the same service, so they wait alike.
let pollingInterval: int

// Every HyperSync-backed source needs a token to reach the service, so a
// missing one fails at construction with the message that says how to get one,
// rather than as a 401 per request.
let requireApiToken: option<string> => string

// Surfaced by the native clients when the edge rejects the API token. The
// corrupted-token test feeds the real server error (from the query endpoint;
// the edge no longer 401s malformed tokens on /height) through this so it can't
// silently drift away from the message shape a 401 actually produces.
let isUnauthorizedError: string => bool

// Rethrows every failure unchanged, adding one loud line the first time a source
// sees a 401. Never swallows it: the caller's retry ramp has to keep asking,
// because a token can be replaced without restarting the indexer.
let rethrowLoggingUnauthorized: (exn, ~warned: ref<bool>, ~product: string) => 'a

// Map a native client's `PREFIX:<int>` failure marker onto the exception
// SourceManager retries on (`RateLimited` / `SourceBehindHead`), falling back to
// the original cause.
let mapNativeFailure: Source.nativeRequestFailure => exn
let mapNativeFailureExn: exn => exn
let reraiseIfRecoverable: exn => unit

// Wrap a native client's paginated block-hash query as a `Source.getBlockHashes`,
// keeping the request timings whether it succeeds or fails.
let makeGetBlockHashes: (
  ~query: (~blockNumbers: array<int>) => promise<(BlockStore.t, array<Source.requestStat>)>,
) => (~blockNumbers: array<int>, ~logger: Pino.t) => promise<Source.getBlockHashesResponse>

module GetLogs: {
  type error =
    | UnexpectedMissingParams({missingParams: array<string>})
    | WrongInstance

  exception Error(error)

  let extractMissingParams: exn => option<array<string>>

  let query: (
    ~client: HyperSyncClient.t,
    ~fromBlock: int,
    ~toBlock: option<int>,
    ~maxNumLogs: option<int>,
    ~registrationIndexes: array<int>,
    ~addressSet: AddressSet.t,
    ~clientFilteredContracts: option<array<string>>,
  ) => promise<logsQueryPage>
}
