type contract = {
  name: string,
  abi: Ethers.abi,
  address: Ethers.ethAddress,
  events: array<string>,
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
    "31337",
    {
      rpcUrl: "http://127.0.0.1:8545",
      chainId: 31337,
      startBlock: 0,
      contracts: [
        {
          name: "GravatarRegistry",
          abi: Abis.gravatarAbi->Ethers.makeAbi,
          address: "0x5FbDB2315678afecb367f032d93F642f64180aa3"->Ethers.getAddressFromStringUnsafe,
          events: ["NewGravatar, UpdateGravatar"],
        },
      ],
    },
  ),
]->Js.Dict.fromArray
