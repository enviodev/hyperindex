type contract = {
  name: string,
  abi: Ethers.abi,
  addresses: array<Ethers.ethAddress>,
  events: array<Types.eventName>,
}

type chainConfig = {
  provider: Ethers.JsonRpcProvider.t,
  startBlock: int,
  chainId: int,
  contracts: array<contract>,
}

type chainConfigs = Js.Dict.t<chainConfig>

// Logging:
@genType
type logLevel = [
  | #TRACE
  | #DEBUG
  | #INFO
  | #WARN
  | #ERROR
  | #FATAL
]

%%private(let envSafe = EnvSafe.make())

let defaultLogLevel =
  envSafe->EnvSafe.get(
    ~name="LOG_LEVEL",
    ~struct=S.union([
      S.literalVariant(String("TRACE"), #TRACE),
      S.literalVariant(String("DEBUG"), #DEBUG),
      S.literalVariant(String("INFO"), #INFO),
      S.literalVariant(String("WARN"), #WARN),
      S.literalVariant(String("ERROR"), #ERROR),
      S.literalVariant(String("FATAL"), #FATAL),
    ]),
    ~devFallback=#INFO,
    (),
  )

let db: Postgres.poolConfig = {
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
  ssl: envSafe->EnvSafe.get(
    ~name="SSL_MODE",
    ~struct=S.string(),
    //this is a dev fallback option for local deployments, shouldn't run in the prod env
    //the SSL modes should be provided as string otherwise as 'require' | 'allow' | 'prefer' | 'verify-full'
    ~devFallback=false->Obj.magic,
    (),
  ),
  onnotice: defaultLogLevel == #WARN || defaultLogLevel == #ERROR ? None : Some(() => ()),
}

let config: chainConfigs = [
  (
    "1337",
    {
      provider: Ethers.JsonRpcProvider.makeStatic(~rpcUrl="http://localhost:8545", ~chainId=1337),
      startBlock: 1,
      chainId: 1337,
      contracts: [
        {
          name: "Gravatar",
          abi: Abis.gravatarAbi->Ethers.makeAbi,
          addresses: [
            "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"->Ethers.getAddressFromStringUnsafe,
          ],
          events: [
            GravatarContract_TestEventEvent,
            GravatarContract_NewGravatarEvent,
            GravatarContract_UpdatedGravatarEvent,
          ],
        },
        {
          name: "NftFactory",
          abi: Abis.nftFactoryAbi->Ethers.makeAbi,
          addresses: [
            "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"->Ethers.getAddressFromStringUnsafe,
          ],
          events: [NftFactoryContract_SimpleNftCreatedEvent],
        },
        {
          name: "SimpleNft",
          abi: Abis.simpleNftAbi->Ethers.makeAbi,
          addresses: [],
          events: [SimpleNftContract_TransferEvent],
        },
      ],
    },
  ),
]->Js.Dict.fromArray

type syncConfig = {
  initialBlockInterval: int,
  backoffMultiplicative: float,
  accelerationAdditive: int,
  intervalCeiling: int,
  backoffMillis: int,
  queryTimeoutMillis: int,
}

let syncConfig = {
  initialBlockInterval: EnvUtils.getIntEnvVar(
    ~envSafe,
    "UNSTABLE__SYNC_INITIAL_BLOCK_INTERVAL",
    ~fallback=10000,
  ),
  // After an RPC error, how much to scale back the number of blocks requested at once
  backoffMultiplicative: EnvUtils.getFloatEnvVar(
    ~envSafe,
    "UNSTABLE__SYNC_BACKOFF_MULTIPLICATIVE",
    ~fallback=0.8,
  ),
  // Without RPC errors or timeouts, how much to increase the number of blocks requested by for the next batch
  accelerationAdditive: EnvUtils.getIntEnvVar(
    ~envSafe,
    "UNSTABLE__SYNC_ACCELERATION_ADDITIVE",
    ~fallback=2000,
  ),
  // Do not further increase the block interval past this limit
  intervalCeiling: EnvUtils.getIntEnvVar(
    ~envSafe,
    "UNSTABLE__SYNC_INTERVAL_CEILING",
    ~fallback=10000,
  ),
  // After an error, how long to wait before retrying
  backoffMillis: 5000,
  // How long to wait before cancelling an RPC request
  queryTimeoutMillis: 20000,
}
