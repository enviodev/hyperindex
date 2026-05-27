type chainParams = {
  chainConfig: Config.chain,
  mutable fetchState: FetchState.t,
  mutable isRealtime: bool,
}

type contractParams = {
  contract: Config.contract,
  chainParams: chainParams,
}

let chainParamsByThis: Utils.WeakMap.t<unknown, chainParams> = Utils.WeakMap.make()
let contractParamsByThis: Utils.WeakMap.t<unknown, contractParams> = Utils.WeakMap.make()

let contractPrototype = %raw(`Object.create(null)`)
Utils.Object.defineProperty(
  contractPrototype,
  "name",
  {
    enumerable: true,
    get: Utils.toMethod(() => {
      (contractParamsByThis->Utils.WeakMap.unsafeGet(%raw(`this`))).contract.name
    }),
  },
)
->Utils.Object.defineProperty(
  "abi",
  {
    enumerable: true,
    get: Utils.toMethod(() => {
      (contractParamsByThis->Utils.WeakMap.unsafeGet(%raw(`this`))).contract.abi
    }),
  },
)
->Utils.Object.defineProperty(
  "addresses",
  {
    enumerable: true,
    get: Utils.toMethod(() => {
      let params = contractParamsByThis->Utils.WeakMap.unsafeGet(%raw(`this`))
      let addresses = []
      params.chainParams.fetchState.indexingAddresses
      ->Dict.valuesToArray
      ->Array.forEach(ia => {
        if ia.contractName === params.contract.name {
          addresses->Array.push(ia.address)->ignore
        }
      })
      addresses
    }),
  },
)
->ignore

%%raw(`
var ContractContext = function(params) {
  contractParamsByThis.set(this, params);
};
ContractContext.prototype = contractPrototype;
`)

@new
external makeContractContext: contractParams => Internal.chainContract = "ContractContext"

let chainPrototype = %raw(`Object.create(null)`)
Utils.Object.defineProperty(
  chainPrototype,
  "id",
  {
    enumerable: true,
    get: Utils.toMethod(() => {
      (chainParamsByThis->Utils.WeakMap.unsafeGet(%raw(`this`))).chainConfig.id
    }),
  },
)
->Utils.Object.defineProperty(
  "name",
  {
    enumerable: true,
    get: Utils.toMethod(() => {
      (chainParamsByThis->Utils.WeakMap.unsafeGet(%raw(`this`))).chainConfig.name
    }),
  },
)
->Utils.Object.defineProperty(
  "startBlock",
  {
    enumerable: true,
    get: Utils.toMethod(() => {
      (chainParamsByThis->Utils.WeakMap.unsafeGet(%raw(`this`))).fetchState.startBlock
    }),
  },
)
->Utils.Object.defineProperty(
  "endBlock",
  {
    enumerable: true,
    get: Utils.toMethod(() => {
      (chainParamsByThis->Utils.WeakMap.unsafeGet(%raw(`this`))).fetchState.endBlock
    }),
  },
)
->Utils.Object.defineProperty(
  "isRealtime",
  {
    enumerable: true,
    get: Utils.toMethod(() => {
      (chainParamsByThis->Utils.WeakMap.unsafeGet(%raw(`this`))).isRealtime
    }),
  },
)
->ignore

%%raw(`
var ChainContext = function(params) {
  chainParamsByThis.set(this, params);
  var contracts = params.chainConfig.contracts;
  for (var i = 0; i < contracts.length; i++) {
    var contract = contracts[i];
    Object.defineProperty(this, contract.name, {
      enumerable: true,
      value: new ContractContext({ contract: contract, chainParams: params })
    });
  }
};
ChainContext.prototype = chainPrototype;
`)

@new
external makeChainContext: chainParams => Internal.chainInfo = "ChainContext"

let getParams = (chainInfo: Internal.chainInfo): chainParams => {
  chainParamsByThis->Utils.WeakMap.unsafeGet(
    chainInfo->(Utils.magic: Internal.chainInfo => unknown),
  )
}

let makeFromConfig = (
  ~chainConfig: Config.chain,
  ~startBlock: int,
  ~endBlock: option<int>,
  ~indexingAddresses: dict<FetchState.indexingAddress>,
  ~isRealtime: bool,
): Internal.chainInfo => {
  let fetchState =
    {"startBlock": startBlock, "endBlock": endBlock, "indexingAddresses": indexingAddresses}->(
      Utils.magic: _ => FetchState.t
    )
  makeChainContext({chainConfig, fetchState, isRealtime})
}
