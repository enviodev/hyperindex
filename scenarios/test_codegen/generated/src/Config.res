type contract = {
  name: string,
  abi: Ethers.abi,
  address: Ethers.ethAddress,
  events: array<Types.eventName>,
}

type chainConfig = {
  rpcUrl: string,
  chainId: int,
  startBlock: int,
  contracts: array<contract>,
}

type chainConfigs = Js.Dict.t<chainConfig>

let config: chainConfigs = [
  (
    "137",
    {
      rpcUrl: "https://polygon-rpc.com",
      chainId: 137,
      startBlock: 34316032,
      contracts: [
        {
          name: "Gravatar",
          abi: Abis.gravatarAbi->Ethers.makeAbi,
          address: "0x2E645469f354BB4F5c8a05B3b30A929361cf77eC"->Ethers.getAddressFromStringUnsafe,
          events: [GravatarContract_NewGravatarEvent, GravatarContract_UpdatedGravatarEvent],
        },
      ],
    },
  ),
]->Js.Dict.fromArray
