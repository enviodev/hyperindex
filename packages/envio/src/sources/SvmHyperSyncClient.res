type cfg = {
  /** HyperSync server URL. */
  url: string,
  /** Optional bearer token for the HyperSync server. */
  apiToken?: string,
  httpReqTimeoutMillis?: int,
  maxNumRetries?: int,
  retryBaseMs?: int,
  retryCeilingMs?: int,
  /// Per-program Borsh schema descriptors (JSON, one per program). The Rust
  /// client builds these into decoders at creation and decodes matching
  /// instructions inline on `get`.
  programSchemas?: array<string>,
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
    | @as("transaction_id") TransactionId
    | @as("has_dropped_log_messages") HasDroppedLogMessages

  type instructionField =
    | @as("slot") Slot
    | @as("transaction_index") TransactionIndex
    | @as("instruction_address") InstructionAddress
    | @as("executing_account") ExecutingAccount
    | @as("executing_account_index") ExecutingAccountIndex
    | @as("account_arguments") AccountArguments
    | @as("account_index_arguments") AccountIndexArguments
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
    | @as("tx_success") TxSuccess
    | @as("error") Error
    | @as("compute_units_consumed") ComputeUnitsConsumed

  type logField =
    | @as("slot") Slot
    | @as("transaction_index") TransactionIndex
    | @as("instruction_address") InstructionAddress
    | @as("program_id") ProgramId
    | @as("kind") Kind
    | @as("message") Message

  // Columns of the unified account_activity table (the merged replacement for
  // the removed balances/token_balances tables).
  type accountActivityField =
    | @as("slot") Slot
    | @as("transaction_index") TransactionIndex
    | @as("transaction_id") TransactionId
    | @as("account_index") AccountIndex
    | @as("account") Account
    | @as("pre_balance") PreBalance
    | @as("post_balance") PostBalance
    | @as("is_signer") IsSigner
    | @as("is_writable") IsWritable
    | @as("is_fee_payer") IsFeePayer
    | @as("from_lookup_table") FromLookupTable
    | @as("mint") Mint
    | @as("pre_owner") PreOwner
    | @as("post_owner") PostOwner
    | @as("token_decimals") TokenDecimals
    | @as("pre_token_balance") PreTokenBalance
    | @as("post_token_balance") PostTokenBalance
    | @as("pre_program_id") PreProgramId
    | @as("post_program_id") PostProgramId
    | @as("token_state") TokenState

  type fieldSelection = {
    block?: array<blockField>,
    transaction?: array<transactionField>,
    instructionCall?: array<instructionField>,
    log?: array<logField>,
    accountActivity?: array<accountActivityField>,
  }

  /** Filter for selecting instructions. All non-empty fields are AND-ed: an
   instruction must match at least one value in every non-empty field.

   Discriminator filters (d1..d8) take hex-encoded byte prefixes ("0x" optional).
   Account filters (a0..a9) take base58 pubkey strings. */
  type instructionSelection = {
    executingAccount?: array<string>,
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
    /// Tri-state filter on the parent transaction's success; absent matches
    /// instructions of both successful and failed transactions.
    txSuccess?: bool,
  }

  type transactionSelection = {
    feePayer?: array<string>,
    success?: bool,
  }

  type logSelection = {
    programId?: array<string>,
    kind?: array<string>,
  }

  type query = {
    fromSlot: int,
    toSlot?: int,
    instructionCalls?: array<instructionSelection>,
    transactions?: array<transactionSelection>,
    logs?: array<logSelection>,
    includeAllBlocks?: bool,
    fields?: fieldSelection,
    maxNumBlocks?: int,
    maxNumTransactions?: int,
    maxNumInstructions?: int,
    maxNumLogs?: int,
    maxNumAccountActivity?: int,
  }
}

module ResponseTypes = {
  // Lean per-slot header for reorg detection and each item's slot/time; the
  // selectable fields live in the block store and are materialised on demand.
  type block = {
    slot: int,
    blockhash: string,
    blockTime?: int,
  }

  /// Borsh-decoded view attached by the Rust client. `argsJson`/`accountsJson`
  /// are stringified to side-step napi-rs's lack of native JSON passthrough.
  /** Solana instruction record.

   `data` is the raw instruction byte buffer, hex-encoded with a `0x` prefix.
   `d1`..`d8` are the same byte prefix as `data` but truncated to N bytes
   (only `Some` when the instruction is at least that long), exposed for
   handler-dispatch convenience.
   `accountArguments` is the full positional account list in base58. */
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
    executingAccount: string,
    accountArguments: array<string>,
    data: string,
    d1?: string,
    d2?: string,
    d4?: string,
    d8?: string,
    isInner: bool,
    txSuccess: bool,
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

  type queryResponseData = {
    blocks: array<block>,
    instructions: array<instruction>,
    logs: array<log>,
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
  // Returns the response plus pages of raw transactions and blocks (kept in
  // Rust), keyed by (slot, transactionIndex) / slot, materialised at batch prep.
  get: (~query: query) => promise<(queryResponse, TransactionStore.t, BlockStore.t)>,
}

@send
external classFromConfig: (Core.svmHypersyncClientCtor, cfg, string) => t = "fromConfig"

let make = (
  ~url,
  ~apiToken=?,
  ~httpReqTimeoutMillis=?,
  ~maxNumRetries=?,
  ~retryBaseMs=?,
  ~retryCeilingMs=?,
  ~programSchemas=?,
) => {
  let envioVersion = Utils.EnvioPackage.value.version
  Core.getAddon().svmHypersyncClient->classFromConfig(
    {
      url,
      ?apiToken,
      ?httpReqTimeoutMillis,
      ?maxNumRetries,
      ?retryBaseMs,
      ?retryCeilingMs,
      ?programSchemas,
    },
    `hyperindex/${envioVersion}`,
  )
}
