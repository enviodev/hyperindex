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
  onnotice: defaultLogLevel == #WARN || defaultLogLevel == #ERROR ? None : Some(() => ()),
}

let config: chainConfigs = [
  (
    "1337",
    {
      provider: Ethers.JsonRpcProvider.make(~rpcUrl="http://localhost:8545", ~chainId=1337),
      startBlock: 0,
      chainId: 1337,
      contracts: [
        {
          name: "Gravatar",
          abi: Abis.gravatarAbi->Ethers.makeAbi,
          address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"->Ethers.getAddressFromStringUnsafe,
          events: [
            GravatarContract_TestEventEvent,
            GravatarContract_NewGravatarEvent,
            GravatarContract_UpdatedGravatarEvent,
          ],
        },
        {
          name: "NftFactory",
          abi: Abis.nftFactoryAbi->Ethers.makeAbi,
          address: "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"->Ethers.getAddressFromStringUnsafe,
          events: [NftFactoryContract_SimpleNftCreatedEvent],
        },
        {
          name: "SimpleNft",
          abi: Abis.simpleNftAbi->Ethers.makeAbi,
          address: "0x93606B31d10C407F13D9702eC4E0290Fd7E32852"->Ethers.getAddressFromStringUnsafe,
          events: [SimpleNftContract_TransferEvent],
        },
      ],
    },
  ),
]->Js.Dict.fromArray
