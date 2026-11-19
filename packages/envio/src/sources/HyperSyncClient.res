/** Determines query serialization format for HTTP requests. */
type serializationFormat =
  // Use JSON serialization (default)
  | Json
  // Use Cap'n Proto binary serialization
  | CapnProto

let serializationFormatSchema = S.enum([Json, CapnProto])

type cfg = {
  /** HyperSync server URL. */
  url: string,
  /** HyperSync server api token. */
  apiToken: string,
  /** Milliseconds to wait for a response before timing out. Default: 30000. */
  httpReqTimeoutMillis?: int,
  /** Number of retries to attempt before returning error. Default: 12. */
  /** Milliseconds that would be used for retry backoff increasing. Default: 500. */
  retryBackoffMs?: int,
  /** Initial wait time for request backoff. Default: 200. */
  retryBaseMs?: int,
  /** Ceiling time for request backoff. Default: 5000. */
  retryCeilingMs?: int,
  /** Enable checksum addresses in responses. */
  /** Query serialization format to use for HTTP requests. Default: Json. */
  serializationFormat?: serializationFormat,
  /** Whether to use query caching when using CapnProto serialization format. */
  enableQueryCaching?: bool,
  logLevel?: string,
}

module Registration = {
  // One topic position of the resolved `where`: `Some([])` matches any value,
  // `Some(values)` one of them, and `None` is the "currently registered
  // addresses of this contract" marker, expanded to padded address topics
  // when Rust builds a query.
  type topicConstraintInput = option<array<string>>

  type topicFilterInput = {
    topic0: topicConstraintInput,
    topic1: topicConstraintInput,
    topic2: topicConstraintInput,
    topic3: topicConstraintInput,
  }

  // The full per-(event, chain) registration passed to the Rust clients at
  // construction: decode metadata, matching identity, and the fetch state
  // queries are built from.
  type input = {
    // Chain-scoped sequential registration index, echoed back on matched items.
    index: int,
    // `None` for an anonymous event.
    sighash: option<string>,
    topicCount: int,
    eventName: string,
    contractName: string,
    isWildcard: bool,
    dependsOnAddresses: bool,
    // Earliest block this registration accepts; `None` is unrestricted. The
    // address store's start block is contract-wide, so it can't hold one
    // registration back when a sibling declares no start block.
    startBlock: option<int>,
    params: array<Internal.paramMeta>,
    topicFilters: array<topicFilterInput>,
    // Capitalized field names matching the Rust BlockField/TransactionField
    // string enums.
    blockFields: array<string>,
    transactionFields: array<string>,
  }

  let toTopicConstraintInput = (topicConstraint: Internal.topicConstraint): topicConstraintInput =>
    switch topicConstraint {
    | Any => Some([])
    | Values(values) => Some(values->EvmTypes.Hex.toStrings)
    | ContractAddresses(_) => None
    }

  let fromOnEventRegistrations = (
    onEventRegistrations: array<Internal.evmOnEventRegistration>,
  ): array<input> => {
    onEventRegistrations->Array.map(reg => {
      let event = reg.eventConfig->(Utils.magic: Internal.eventConfig => Internal.evmEventConfig)
      {
        index: reg.index,
        sighash: event.sighash,
        topicCount: event.topicCount,
        eventName: event.name,
        contractName: event.contractName,
        isWildcard: reg.isWildcard,
        dependsOnAddresses: reg.dependsOnAddresses,
        startBlock: reg.startBlock,
        params: event.paramsMetadata,
        topicFilters: reg.resolvedWhere.topicFilters->Array.map((filter): topicFilterInput => {
          topic0: filter.topic0->toTopicConstraintInput,
          topic1: filter.topic1->toTopicConstraintInput,
          topic2: filter.topic2->toTopicConstraintInput,
          topic3: filter.topic3->toTopicConstraintInput,
        }),
        // Capitalized to match the Rust BlockField/TransactionField string
        // enums.
        blockFields: reg.fieldSelection.blockFields
        ->Utils.Set.toArray
        ->Array.map(Utils.String.capitalize),
        transactionFields: reg.fieldSelection.transactionFields
        ->Utils.Set.toArray
        ->Array.map(Utils.String.capitalize),
      }
    })
  }
}

module Items = {
  // The whole per-query input beside the partition's address set: block range
  // and what it selects from each table. Log selections, field selection, and
  // the matching index are derived on the Rust side.
  type query = {
    fromBlock: int,
    // Inclusive; None queries to the end of available data.
    toBlock: option<int>,
    onEventRegistrationIndexes: array<int>,
    onBlockRegistrationIndexes: array<int>,
    onTransactionRegistrationIndexes: array<int>,
    // Contract names to fetch address-free even though their registrations
    // depend on addresses (client-side filtering). None/empty means
    // every address-dependent contract is filtered server-side.
    clientFilteredContracts: option<array<string>>,
    // Blocks at or above this one can still be reorged, so a page reaching
    // them reads every block of its range. Absent when the range is final.
    reorgableFrom?: int,
  }

  type response = {
    archiveHeight: option<int>,
    nextBlock: int,
    // Blocks the server returned for the query, counted before matching drops
    // the ones no item joins to.
    responseBlocks: int,
  }
}

type t = {
  // Block-hash query construction and pagination live in Rust; only the
  // aggregate response store crosses the boundary.
  getBlockHashes: (~blockNumbers: array<int>) => promise<(BufferPage.t, array<RequestStat.t>)>,
  // Returns the response plus the page of rows some registration matches. A
  // query for blocks alone skips the blocks `buffer` holds with every field
  // its handlers select.
  getItems: (
    ~query: Items.query,
    ~addressSet: AddressSet.t,
    ~buffer: BufferPage.buffer,
  ) => promise<(Items.response, BufferPage.t)>,
  getHeight: unit => promise<int>,
}

@send
external classNew: (
  Core.evmHyperSyncClientCtor,
  cfg,
  string,
  // The chain's compiled registrations, block handlers and addresses.
  BufferPage.buffer,
) => t = "new"

type logLevel = [#trace | #debug | #info | #warn | #error]
let logLevelSchema: S.t<logLevel> = S.enum([#trace, #debug, #info, #warn, #error])

let logLevelToString = (level: logLevel) =>
  switch level {
  | #trace => "trace"
  | #debug => "debug"
  | #info => "info"
  | #warn => "warn"
  | #error => "error"
  }

let make = (
  ~url,
  ~apiToken,
  ~httpReqTimeoutMillis,
  ~chainBuffer,
  ~serializationFormat=?,
  ~enableQueryCaching=?,
  ~retryBaseMs=?,
  ~retryBackoffMs=?,
  ~retryCeilingMs=?,
  ~logLevel=#info,
) => {
  let envioVersion = Utils.EnvioPackage.value.version
  Core.getAddon().evmHyperSyncClient->classNew(
    {
      url,
      apiToken,
      httpReqTimeoutMillis,
      ?serializationFormat,
      ?enableQueryCaching,
      ?retryBaseMs,
      ?retryBackoffMs,
      ?retryCeilingMs,
      logLevel: logLevelToString(logLevel),
    },
    `hyperindex/${envioVersion}`,
    chainBuffer,
  )
}
