type t

type cfg = {
  url: string,
  apiToken: string,
}

type receiptSelection = {
  rootContractId?: array<Address.t>,
  receiptType?: array<FuelSDK.receiptType>,
  txStatus?: array<int>,
  rb?: array<bigint>,
}

type block = {
  id: string,
  time: int,
  height: int,
}

type item = {
  transactionId: string,
  contractId: Address.t,
  receipt: FuelSDK.Receipt.t,
  receiptIndex: int,
  block: block,
}

type logsQueryPage = {
  items: array<item>,
  nextBlock: int,
  archiveHeight: int,
}

type blockDataWithTimestamp = ReorgDetection.blockDataWithTimestamp

let _instantiate: (Core.hyperfuelClientCtor, cfg) => t = %raw(`(C, cfg) => new C(cfg)`)

let make = (cfg: cfg) => _instantiate(Core.getAddon().hyperfuelClient, cfg)

@send
external getLogs: (
  t,
  ~fromBlock: int,
  ~toBlockExclusive: Null.t<int>,
  ~receiptsSelection: array<receiptSelection>,
) => promise<logsQueryPage> = "getLogs"

@send
external queryBlockData: (
  t,
  ~blockNumber: int,
) => promise<Null.t<blockDataWithTimestamp>> = "queryBlockData"
