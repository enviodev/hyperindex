type contract = {
  name: string,
  abi: Ethers.abi,
  address: Ethers.ethAddress,
  events: array<Types.eventName>,
}

type chainConfig = {
  provider: Ethers.JsonRpcProvider.t,
  startBlock: int,
  chainId: int,
  contracts: array<contract>,
}

type chainConfigs = Js.Dict.t<chainConfig>

%%private(let envSafe = EnvSafe.make())

let db: DrizzleOrm.Pool.poolConfig = {
  host: envSafe->EnvSafe.get(~name="PG_HOST", ~struct=S.string(), ~devFallback="localhost", ()),
  port: envSafe->EnvSafe.get(~name="PG_PORT", ~struct=S.int()->S.Int.port(), ~devFallback=5432, ()),
  user: envSafe->EnvSafe.get(~name="PG_USER", ~struct=S.string(), ~devFallback="postgres", ()),
  password: envSafe->EnvSafe.get(
    ~name="PG_PASSWORD",
    ~struct=S.string(),
    ~devFallback="testing",
    (),
  ),
  database: envSafe->EnvSafe.get(
    ~name="PG_DATABASE",
    ~struct=S.string(),
    ~devFallback="envio-dev",
    (),
  ),
}

let config: chainConfigs = [
  (
    "137",
    {
      provider: Ethers.JsonRpcProvider.make(~rpcUrl="https://polygon-rpc.com", ~chainId=137),
      startBlock: 34316032,
      chainId: 137,
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
