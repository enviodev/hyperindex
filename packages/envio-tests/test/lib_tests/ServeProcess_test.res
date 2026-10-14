open Vitest

describe("ServeProcess.port", () => {
  // Hasura already holds 8080 when it runs, so serve moves aside then.
  it("takes 8080 in place of Hasura, 8090 beside it, or ENVIO_SERVE_PORT", t => {
    t.expect([
      ServeProcess.port(~env=dict{}, ~hasuraEnabled=false),
      ServeProcess.port(~env=dict{}, ~hasuraEnabled=true),
      ServeProcess.port(~env=dict{"ENVIO_SERVE_PORT": "8091"}, ~hasuraEnabled=true),
      ServeProcess.port(~env=dict{"ENVIO_SERVE_PORT": ""}, ~hasuraEnabled=false),
    ]).toEqual([8080, 8090, 8091, 8080])
  })
})

describe("ServeProcess.childEnv", () => {
  let keys = [
    "UNRELATED",
    "ENVIO_PG_HOST",
    "ENVIO_PG_PORT",
    "ENVIO_PG_USER",
    "ENVIO_PG_PASSWORD",
    "ENVIO_PG_DATABASE",
    "ENVIO_PG_SCHEMA",
    "HASURA_GRAPHQL_ADMIN_SECRET",
    "ENVIO_SERVE_ACTIONS_PATH",
    "ENVIO_SIDECAR_RESOLVERS_URL",
  ]

  it("hands serve the indexer's database and the actions file, sidecar on loopback", t => {
    let env = ServeProcess.childEnv(
      ~env=dict{
        "UNRELATED": "kept",
        "ENVIO_PG_USER": "me",
        "ENVIO_SIDECAR_RESOLVERS_URL": "http://host.docker.internal:9900",
        "ENVIO_SIDECAR_PORT": "9911",
      },
      ~actionsPath=Some("/project/.envio/actions.json"),
    )
    t.expect(keys->Array.map(key => env->Dict.get(key))).toEqual([
      Some("kept"),
      Some(Env.Db.host),
      Some(Env.Db.port->Int.toString),
      Some("me"),
      Some(Env.Db.password),
      Some(Env.Db.database),
      Some(Env.Db.publicSchema),
      Some(Env.Hasura.secret),
      Some("/project/.envio/actions.json"),
      Some("http://127.0.0.1:9911"),
    ])
  })

  it("leaves the actions out without resolvers", t => {
    let env = ServeProcess.childEnv(~env=dict{}, ~actionsPath=None)
    t.expect(env->Dict.get("ENVIO_SERVE_ACTIONS_PATH")).toEqual(None)
  })
})

describe("ServeProcess.args", () => {
  it("serves the project directory and its config on loopback", t => {
    t.expect([
      ServeProcess.args(~env=dict{}, ~cwd="/project", ~port=8080),
      ServeProcess.args(~env=dict{"ENVIO_CONFIG": "other.yaml"}, ~cwd="/project", ~port=8090),
    ]).toEqual([
      ["--directory", "/project", "--config", "config.yaml", "--host", "127.0.0.1", "--port", "8080"],
      ["--directory", "/project", "--config", "other.yaml", "--host", "127.0.0.1", "--port", "8090"],
    ])
  })
})

describe("SidecarProcess.devEnv with envio serve", () => {
  it("reads through serve when it replaces Hasura, through Hasura otherwise", t => {
    let graphqlUrl = (~env, ~hasuraEnabled) =>
      SidecarProcess.devEnv(~env, ~hasuraEnabled, ())->Dict.get("ENVIO_GRAPHQL_URL")
    t.expect([
      graphqlUrl(~env=dict{"ENVIO_SERVE_BIN": "/bin/envio-serve"}, ~hasuraEnabled=false),
      graphqlUrl(
        ~env=dict{"ENVIO_SERVE_BIN": "/bin/envio-serve", "ENVIO_SERVE_PORT": "8095"},
        ~hasuraEnabled=false,
      ),
      graphqlUrl(~env=dict{"ENVIO_SERVE_BIN": "/bin/envio-serve"}, ~hasuraEnabled=true),
      graphqlUrl(~env=dict{}, ~hasuraEnabled=false),
    ]).toEqual([
      Some("http://127.0.0.1:8080/v1/graphql"),
      Some("http://127.0.0.1:8095/v1/graphql"),
      Some(`${Env.Hasura.url}/v1/graphql`),
      Some(`${Env.Hasura.url}/v1/graphql`),
    ])
  })
})

describe("ServeProcess.actionsMetadata", () => {
  it("templates the sidecar URL and the secret for serve to fill from its env", t => {
    let config = InternalTestIndexer.fromUserApi(
      ~configYaml=`
name: serve-actions
sidecar:
  contract: src/sidecar/contract.ts
  entry: src/sidecar/index.ts
resolvers:
  topTraders:
    args:
      limit: Int
    output: "[BigInt!]!"
    handler: sidecar
chains:
  - id: 1
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "NewGravatar(uint256 id, address owner, string displayName, string imageUrl)"
`,
      ~schema=`
type Probe {
  id: ID!
}
`,
    ).config
    t.expect(ServeProcess.actionsMetadata(~config, ~withSecret=true)->JSON.stringifyAny).toEqual(
      JSON.stringifyAny({
        "actions": [
          {
            "name": "topTraders",
            "definition": {
              "type": "query",
              "kind": "synchronous",
              "handler": "{{ENVIO_SIDECAR_RESOLVERS_URL}}/resolvers/topTraders",
              "arguments": [{"name": "limit", "type": "Int"}],
              "output_type": "[BigInt!]!",
              "timeout": 30,
              "headers": [
                {
                  "name": "x-hasura-envio-resolver-secret",
                  "value_from_env": "ENVIO_RESOLVER_SECRET",
                },
              ],
            },
            "permissions": [{"role": "public"}],
          },
        ],
        "custom_types": {
          "scalars": [{"name": "BigInt"}],
          "enums": [],
          "input_objects": [],
          "objects": [],
        },
      }),
    )
  })
})
