open Belt

let getDefaultAddress = (chain, contractName) => {
  let chainConfig = Config.config->ChainMap.get(chain)
  let contract = chainConfig.contracts->Js.Array2.find(c => c.name == contractName)->Option.getExn
  let defaultAddress = contract.addresses[0]->Option.getExn
  defaultAddress
}

module ERC20 = {
  let contractName = "ERC20"

  module Transfer = {
    let accessor = Types.eRC20Contract_Transfer
    let serializer = Types.ERC20Contract.TransferEvent.eventArgs_encode
    let eventName = Types.ERC20_Transfer
    let mkEventConstrWithParamsAndAddress = ChainMocking.makeEventConstructor(
      ~accessor,
      ~serializer,
      ~eventName,
    )

    let mkEventConstr = (params, ~chain) =>
      mkEventConstrWithParamsAndAddress(~srcAddress=getDefaultAddress(chain, contractName), ~params)
  }
}

module ERC20Factory = {
  let contractName = "ERC20Factory"

  module TokenCreated = {
    let accessor = Types.eRC20FactoryContract_TokenCreated
    let serializer = Types.ERC20FactoryContract.TokenCreatedEvent.eventArgs_encode
    let eventName = Types.ERC20Factory_TokenCreated
    let mkEventConstrWithParamsAndAddress = ChainMocking.makeEventConstructor(
      ~accessor,
      ~serializer,
      ~eventName,
    )

    let mkEventConstr = (params, ~chain) =>
      mkEventConstrWithParamsAndAddress(~srcAddress=getDefaultAddress(chain, contractName), ~params)
  }
}
