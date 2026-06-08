type cfg = {
  /** HyperSync server URL. */
  url: string,
  /** Optional bearer token for the HyperSync server. */
  apiToken?: string,
  httpReqTimeoutMillis?: int,
  maxNumRetries?: int,
  retryBaseMs?: int,
  retryCeilingMs?: int,
}

module QueryTypes = {
  type blockField =
    | @as("slot") Slot
    | @as("blockhash") Blockhash
    | @as("parent_slot") ParentSlot
    | @as("parent_blockhash") ParentBlockhash
    | @as("block_time") BlockTime
    | @as("block_height") BlockHeight

  type transactionField =
    | @as("slot") Slot
    | @as("transaction_index") TransactionIndex
    | @as("signatures") Signatures
    | @as("fee_payer") FeePayer
    | @as("success") Success
    | @as("err") Err
    | @as("fee") Fee
    | @as("compute_units_consumed") ComputeUnitsConsumed
    | @as("account_keys") AccountKeys
    | @as("recent_blockhash") RecentBlockhash
    | @as("version") Version
    | @as("loaded_addresses_writable") LoadedAddressesWritable
    | @as("loaded_addresses_readonly") LoadedAddressesReadonly

  type instructionField =
    | @as("slot") Slot
    | @as("transaction_index") TransactionIndex
    | @as("instruction_address") InstructionAddress
    | @as("program_id") ProgramId
    | @as("accounts") Accounts
    | @as("data") Data
    | @as("d1") D1
    | @as("d2") D2
    | @as("d4") D4
    | @as("d8") D8
    | @as("a0") A0
    | @as("a1") A1
    | @as("a2") A2
    | @as("a3") A3
    | @as("a4") A4
    | @as("a5") A5
    | @as("a6") A6
    | @as("a7") A7
    | @as("a8") A8
    | @as("a9") A9
    | @as("is_inner") IsInner
    | @as("is_committed") IsCommitted

  type logField =
    | @as("slot") Slot
    | @as("transaction_index") TransactionIndex
    | @as("instruction_address") InstructionAddress
    | @as("program_id") ProgramId
    | @as("kind") Kind
    | @as("message") Message

  type tokenBalanceField =
    | @as("slot") Slot
    | @as("transaction_index") TransactionIndex
    | @as("account") Account
    | @as("mint") Mint
    | @as("owner") Owner
    | @as("pre_amount") PreAmount
    | @as("post_amount") PostAmount

  type fieldSelection = {
    block?: array<blockField>,
    transaction?: array<transactionField>,
    instruction?: array<instructionField>,
    log?: array<logField>,
    tokenBalance?: array<tokenBalanceField>,
  }

  /** Filter for selecting instructions. All non-empty fields are AND-ed: an
   instruction must match at least one value in every non-empty field.

   Discriminator filters (d1..d8) take hex-encoded byte prefixes ("0x" optional).
   Account filters (a0..a9) take base58 pubkey strings. */
  type instructionSelection = {
    programId?: array<string>,
    d1?: array<string>,
    d2?: array<string>,
    d4?: array<string>,
    d8?: array<string>,
    a0?: array<string>,
    a1?: array<string>,
    a2?: array<string>,
    a3?: array<string>,
    a4?: array<string>,
    a5?: array<string>,
    a6?: array<string>,
    a7?: array<string>,
    a8?: array<string>,
    a9?: array<string>,
    isInner?: bool,
    includeTransaction?: bool,
    includeLogs?: bool,
    includeTokenBalances?: bool,
  }

  type transactionSelection = {
    feePayer?: array<string>,
    success?: bool,
    includeInstructions?: bool,
  }

  type logSelection = {
    programId?: array<string>,
    kind?: array<string>,
    includeTransaction?: bool,
    includeInstruction?: bool,
  }

  /// Reference to a program's registered Borsh schema, passed with the query
  /// so the Rust client decodes matching instructions inline (in `get`).
  type programSchemaRef = {
    programId: string,
    schemaHandle: int,
  }

  type query = {
    fromSlot: int,
    toSlot?: int,
    instructions?: array<instructionSelection>,
    transactions?: array<transactionSelection>,
    logs?: array<logSelection>,
    includeAllBlocks?: bool,
    includeTokenBalances?: bool,
    fields?: fieldSelection,
    maxNumBlocks?: int,
    maxNumTransactions?: int,
    maxNumInstructions?: int,
    maxNumLogs?: int,
    maxNumTokenBalances?: int,
    programSchemas?: array<programSchemaRef>,
  }
}

module ResponseTypes = {
  type block = {
    slot: int,
    blockhash: string,
    parentSlot?: int,
    parentBlockhash?: string,
    blockTime?: int,
    blockHeight?: int,
  }

  type transaction = {
    slot: int,
    transactionIndex: int,
    signatures: array<string>,
    feePayer?: string,
    success?: bool,
    err?: string,
    fee?: int,
    computeUnitsConsumed?: int,
    accountKeys: array<string>,
    recentBlockhash?: string,
    version?: string,
    loadedAddressesWritable: array<string>,
    loadedAddressesReadonly: array<string>,
  }

  /// Borsh-decoded view attached by the Rust client. `argsJson`/`accountsJson`
  /// are stringified to side-step napi-rs's lack of native JSON passthrough.
  /** Solana instruction record.

   `data` is the raw instruction byte buffer, hex-encoded with a `0x` prefix.
   `d1`..`d8` are the same byte prefix as `data` but truncated to N bytes
   (only `Some` when the instruction is at least that long), exposed for
   handler-dispatch convenience.
   `accounts` is the full positional account list in base58. */
  type decodedInstruction = {
    name: string,
    argsJson: string,
    accountsJson: string,
    extraAccounts: array<string>,
  }

  type instruction = {
    slot: int,
    transactionIndex: int,
    instructionAddress: array<int>,
    programId: string,
    accounts: array<string>,
    data: string,
    d1?: string,
    d2?: string,
    d4?: string,
    d8?: string,
    isInner: bool,
    isCommitted: bool,
    decoded?: decodedInstruction,
  }

  type log = {
    slot: int,
    transactionIndex?: int,
    instructionAddress?: array<int>,
    programId?: string,
    kind?: string,
    message?: string,
  }

  type tokenBalance = {
    slot: int,
    transactionIndex?: int,
    account?: string,
    mint?: string,
    owner?: string,
    preAmount?: string,
    postAmount?: string,
  }

  type queryResponseData = {
    blocks: array<block>,
    transactions: array<transaction>,
    instructions: array<instruction>,
    logs: array<log>,
    tokenBalances: array<tokenBalance>,
  }

  type queryResponse = {
    nextSlot: int,
    responseBytes: int,
    data: queryResponseData,
  }
}

type query = QueryTypes.query
type queryResponse = ResponseTypes.queryResponse

type t = {
  getHeight: unit => promise<int>,
  get: (~query: query) => promise<queryResponse>,
}

@send
external classFromConfig: (Core.hypersyncSolanaClientCtor, cfg) => t = "fromConfig"

let make = (
  ~url,
  ~apiToken=?,
  ~httpReqTimeoutMillis=?,
  ~maxNumRetries=?,
  ~retryBaseMs=?,
  ~retryCeilingMs=?,
) => {
  Core.getAddon().hypersyncSolanaClient->classFromConfig({
    url,
    ?apiToken,
    ?httpReqTimeoutMillis,
    ?maxNumRetries,
    ?retryBaseMs,
    ?retryCeilingMs,
  })
}
