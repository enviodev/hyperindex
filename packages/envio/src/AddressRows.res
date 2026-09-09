type key = {
  chainId: ChainId.t,
  address: NodeJs.Buffer.t,
  contractId: int,
}

type row = {
  chainId: ChainId.t,
  address: NodeJs.Buffer.t,
  contractId: int,
  registrationBlock: int,
}

type staged = {
  row: row,
  checkpointId: Internal.checkpointId,
}

type seedRows = {
  addresses: array<NodeJs.Buffer.t>,
  contractIds: array<int>,
  registrationBlocks: array<int>,
}

let emptySeedRows = (): seedRows => {
  addresses: [],
  contractIds: [],
  registrationBlocks: [],
}

// Config addresses are registered by no event. Rollback never reaches them.
let configRegistrationBlock = -1

let keyOf = (row: row): key => {
  chainId: row.chainId,
  address: row.address,
  contractId: row.contractId,
}

let packBuffers = (addresses: array<NodeJs.Buffer.t>) => (
  NodeJs.Buffer.concat(addresses),
  addresses->Array.map(address => address->NodeJs.Buffer.length),
)

let packKeys = (rows: array<row>) => packBuffers(rows->Array.map(row => row.address))

let seedRowsOf = (rows: array<row>): seedRows => {
  let addresses = []
  let contractIds = []
  let registrationBlocks = []
  rows->Array.forEach(row => {
    addresses->Array.push(row.address)->ignore
    contractIds->Array.push(row.contractId)->ignore
    registrationBlocks->Array.push(row.registrationBlock)->ignore
  })
  {addresses, contractIds, registrationBlocks}
}

// Rows arrive clustered per chain. Normalizing a chain id is a schema parse.
let group = (rows: array<row>): dict<seedRows> => {
  let rowsByChain: dict<array<row>> = Dict.make()
  let runChainId = ref(None)
  let runKey = ref("")
  rows->Array.forEach(row => {
    if runChainId.contents !== Some(row.chainId) {
      runChainId := Some(row.chainId)
      runKey := row.chainId->ChainId.normalizeOrThrow->ChainId.toString
    }
    rowsByChain->Utils.Dict.push(runKey.contents, row)
  })
  rowsByChain->Utils.Dict.mapValues(seedRowsOf)
}

module Table = {
  type t = dict<row>

  let dictKey = (key: key) =>
    `${key.chainId->ChainId.toString}|${key.contractId->Int.toString}|${key.address->NodeJs.Buffer.toBase64}`

  let make = (): t => Dict.make()

  let clear = (table: t) => table->Utils.Dict.clearInPlace

  let insert = (table: t, row: row) => {
    let key = row->keyOf->dictKey
    switch table->Utils.Dict.dangerouslyGetNonOption(key) {
    | Some(_) => ()
    | None => table->Dict.set(key, row)
    }
  }

  let insertMany = (table: t, rows: array<row>) => rows->Array.forEach(row => table->insert(row))

  let delete = (table: t, key: key) => table->Utils.Dict.deleteInPlace(key->dictKey)

  let rows = (table: t): array<row> => table->Dict.valuesToArray

  let groupByChain = (table: t) => table->rows->group
}

let render = (rows: array<row>, ~ecosystem: string, ~shouldChecksum: bool) => {
  let (bytes, lengths) = rows->packKeys
  Core.getAddon().renderAddresses(~ecosystem, ~shouldChecksum, ~bytes, ~lengths)
}

let renderOfContract = (
  rows: seedRows,
  ~ecosystem: string,
  ~shouldChecksum: bool,
  ~contractId: int,
) => {
  let (bytes, lengths) = packBuffers(rows.addresses)
  Core.getAddon().renderContractAddresses(
    ~ecosystem,
    ~shouldChecksum,
    ~bytes,
    ~lengths,
    ~contractIds=rows.contractIds,
    ~contractId,
  )
}
