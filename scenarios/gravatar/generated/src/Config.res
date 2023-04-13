type contract = {
  name: string,
  abi: Ethers.abi,
  address: Ethers.ethAddress,
  events: array<string>,
}

type chainConfig = {
  provider: Ethers.JsonRpcProvider.t,
  startBlock: int,
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
    ~devFallback="indexly-dev",
    (),
  ),
}

let config: chainConfigs = [
  (
    "31337",
    {
      provider: Ethers.JsonRpcProvider.make(~rpcUrl="http://127.0.0.1:8545", ~chainId=31337),
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
