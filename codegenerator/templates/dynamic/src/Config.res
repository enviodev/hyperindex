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

let defaultLogLevel = envSafe->EnvSafe.get(
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
  onnotice: (defaultLogLevel == #WARN || defaultLogLevel == #ERROR) ? None : Some(() => ())
}

let config: chainConfigs = [
{{#each chain_configs as | chain_config |}}
(
  "{{chain_config.network_config.id}}",
  {
    provider: Ethers.JsonRpcProvider.make(~rpcUrl="{{chain_config.network_config.rpc_url}}", ~chainId={{chain_config.network_config.id}}),
    startBlock: {{chain_config.network_config.start_block}},
    chainId: {{chain_config.network_config.id}},
    contracts: [
      {{#each chain_config.contracts as | contract |}}
      {
        name: "{{contract.name.capitalized}}",
          abi: Abis.{{contract.name.uncapitalized}}Abi->Ethers.makeAbi,
          address: "{{contract.address}}"->Ethers.getAddressFromStringUnsafe,
          events: [
            {{#each contract.events as | event |}}
            {{contract.name.capitalized}}Contract_{{event.capitalized}}Event,
            {{/each}}
            ],
      },
      {{/each}}
    ]

  }
),
{{/each}}
]->Js.Dict.fromArray
