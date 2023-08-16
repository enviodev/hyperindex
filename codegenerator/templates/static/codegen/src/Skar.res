
@spice
type unchecksummedEthAddress = string

module SkarQuery = {
  @spice
  type blockFieldSelection = {
    parentHash?: bool,
    sha3Uncles?: bool,
    miner?: bool,
    stateRoot?: bool,
    transactionsRoot?: bool,
    receiptsRoot?: bool,
    logsBloom?: bool,
    difficulty?: bool,
    number?: bool,
    gasLimit?: bool,
    gasUsed?: bool,
    timestamp?: bool,
    extraData?: bool,
    mixHash?: bool,
    nonce?: bool,
    totalDifficulty?: bool,
    baseFeePerGas?: bool,
    size?: bool,
    hash?: bool,
  }

  @spice
  type transactionFieldSelection = {
    @spice.key("type") @as("type") type_?: bool,
    nonce?: bool,
    to?: bool,
    gas?: bool,
    value?: bool,
    input?: bool,
    maxPriorityFeePerGas?: bool,
    maxFeePerGas?: bool,
    yParity?: bool,
    chainId?: bool,
    v?: bool,
    r?: bool,
    s?: bool,
    from?: bool,
    blockHash?: bool,
    blockNumber?: bool,
    index?: bool,
    gasPrice?: bool,
    hash?: bool,
    status?: bool,
  }

  @spice
  type logFieldSelection = {
    address?: bool,
    blockHash?: bool,
    blockNumber?: bool,
    data?: bool,
    index?: bool,
    removed?: bool,
    topics?: bool,
    transactionHash?: bool,
    transactionIndex?: bool,
  }

  @spice
  type fieldSelection = {
    block?: blockFieldSelection,
    transaction?: transactionFieldSelection,
    log?: logFieldSelection,
  }

  @spice
  type logParams = {
    address?: array<Ethers.ethAddress>,
    topics: array<array<Ethers.EventFilter.topic>>,
    fieldSelection: fieldSelection,
  }

  @spice
  type transactionParams = {
    address?: array<Ethers.ethAddress>,
    sighash?: array<string>,
    fieldSelection: fieldSelection,
  }

  @spice
  type postQueryBody = {
    fromBlock: int,
    toBlock?: int,
    logs?: array<logParams>,
    transactions?: array<transactionParams>,
  }
}
module SkarResponse = {
  @spice
  type blockData = {
    parentHash?: string,
    sha3Uncles?: string,
    miner?: unchecksummedEthAddress,
    stateRoot?: string,
    transactionsRoot?: string,
    receiptsRoot?: string,
    logsBloom?: string,
    difficulty?: Ethers.BigInt.t,
    number?: int,
    gasLimit?: Ethers.BigInt.t,
    gasUsed?: Ethers.BigInt.t,
    timestamp?: Ethers.BigInt.t,
    extraData?: string,
    mixHash?: string,
    nonce?: int,
    totalDifficulty?: Ethers.BigInt.t,
    baseFeePerGas?: Ethers.BigInt.t,
    size?: Ethers.BigInt.t,
    hash?: string,
  }

  @spice
  type transactionData = {
    @as("type") type_?: int,
    nonce?: int,
    to?: unchecksummedEthAddress,
    gas?: Ethers.BigInt.t,
    value?: Ethers.BigInt.t,
    input?: string,
    maxPriorityFeePerGas?: Ethers.BigInt.t,
    maxFeePerGas?: Ethers.BigInt.t,
    chainId?: int,
    v?: string,
    r?: string,
    s?: string,
    from?: unchecksummedEthAddress,
    blockHash?: string,
    blockNumber?: int,
    index?: int,
    gasPrice?: Ethers.BigInt.t,
    hash?: string,
  }

  @spice
  type logData = {
    address?: unchecksummedEthAddress,
    blockHash?: string,
    blockNumber?: int,
    data?: string,
    index?: int,
    removed?: bool,
    topics?: array<string>,
    transactionHash?: string,
    transactionIndex?: int,
  }

  @spice
  type data = {
    block?: blockData,
    transactions?: array<transactionData>,
    logs?: array<logData>,
  }

  @spice
  type t = {
    data: array<array<data>>,
    archiveHeight: int,
    nextBlock: int,
    totalTime: int,
  }
}

type skarQueryError = Deserialize(string) | Other

let executeSkarQuery = async (~serverUrl, ~postQueryBody: SkarQuery.postQueryBody): result<
  SkarResponse.t,
  skarQueryError,
> => {
  let queryEndpoint = serverUrl ++ "/query"
  try {
    open Fetch
    //Not encoding with spice since all param types are js primitives
    let body = postQueryBody->Js.Json.stringifyAny->Belt.Option.getExn->Body.string

    let res = await fetch(
      queryEndpoint,
      {method: #POST, headers: Headers.fromObject({"Content-type": "application/json"}), body},
    )

    let data = await res->Response.json

    switch data->SkarResponse.t_decode {
    | Error(e) => Error(Deserialize(e.message))
    | Ok(v) => Ok(v)
    }
  } catch {
  | _ => Error(Other)
  }
}

@spice
type heightResponse = {height: int}

let getArchiveHeight = async (~serverUrl) => {
  try {
    open Fetch
    let heightEndpoint = serverUrl ++ "/height"
    let res = await fetch(heightEndpoint, {method: #GET})

    let data = await res->Response.json

    switch data->heightResponse_decode {
    | Error(e) => Error(Deserialize(e.message))
    | Ok(v) => Ok(v.height)
    }
  } catch {
  | _ => Error(Other)
  }
}
