open Vitest

let version = "1.2.3"

let host = (~env=dict{}, ~hasDockerEnv=false): UserAgent.host => {
  platform: "linux",
  arch: "x64",
  nodeVersion: "22.18.0",
  env,
  hasDockerEnv,
}

let envOf = (h: UserAgent.host) => (h->UserAgent.hostFacts).env
let ciOf = (h: UserAgent.host) => (h->UserAgent.hostFacts).ci

describe("UserAgent.format", () => {
  it("lists every fact in a fixed order", t => {
    t.expect(
      UserAgent.format(
        ~version,
        {
          os: "linux",
          arch: "arm64",
          nodeMajor: 24,
          ecosystem: Evm,
          storage: {postgres: true, clickhouse: true},
          ci: false,
          env: Docker,
        },
      ),
    ).toBe(
      "hyperindex/1.2.3 (os=linux; arch=arm64; node=24; ecosystem=evm; storage=postgres+clickhouse; ci=0; env=docker)",
    )
  })

  it("leaves out the facts it doesn't have", t => {
    t.expect([
      UserAgent.format(~version, {}),
      UserAgent.format(~version, {arch: "x64", env: Local}),
      UserAgent.format(~version, {ecosystem: Fuel, storage: {postgres: true, clickhouse: false}}),
      UserAgent.format(~version, {ci: true, storage: {postgres: false, clickhouse: false}}),
    ]).toEqual([
      "hyperindex/1.2.3",
      "hyperindex/1.2.3 (arch=x64; env=local)",
      "hyperindex/1.2.3 (ecosystem=fuel; storage=postgres)",
      "hyperindex/1.2.3 (ci=1)",
    ])
  })

  // A value that could break the format or name a machine is dropped whole:
  // a tidied-up path or hostname would still name it.
  it("leaves out a value that isn't one Node reports", t => {
    t.expect([
      UserAgent.format(~version, {os: "linux; env=envio-cloud", env: Local}),
      UserAgent.format(~version, {arch: "/home/alice/indexer", env: Local}),
      UserAgent.format(~version, {os: "indexer-7f9c4d6b8-xk2p1", env: Local}),
      UserAgent.format(~version, {os: "Darwin", env: Local}),
      UserAgent.format(~version, {nodeMajor: -1, env: Local}),
    ]).toEqual([
      "hyperindex/1.2.3 (env=local)",
      "hyperindex/1.2.3 (env=local)",
      "hyperindex/1.2.3 (env=local)",
      "hyperindex/1.2.3 (env=local)",
      "hyperindex/1.2.3 (env=local)",
    ])
  })
})

describe("UserAgent.hostFacts", () => {
  // Envio Cloud runs on Kubernetes and Kubernetes runs containers, so each
  // check would also match the ones below it.
  it("names the most specific place the indexer runs", t => {
    t.expect(
      [
        host(
          ~env=dict{
            "ENVIO_OPERATOR_URL": "http://example.test",
            "KUBERNETES_SERVICE_HOST": "10.0.0.1",
          },
          ~hasDockerEnv=true,
        ),
        host(~env=dict{"KUBERNETES_SERVICE_HOST": "10.0.0.1"}, ~hasDockerEnv=true),
        host(~hasDockerEnv=true),
        host(~env=dict{"ENVIO_OPERATOR_URL": ""}),
        host(),
      ]->Array.map(envOf),
    ).toEqual([Some(EnvioCloud), Some(Kubernetes), Some(Docker), Some(Local), Some(Local)])
  })

  // `CI=false` is a common way to turn off a tool's CI behaviour locally.
  it("counts CI as set unless it's empty, 0 or false", t => {
    t.expect(
      [
        host(),
        host(~env=dict{"CI": ""}),
        host(~env=dict{"CI": "0"}),
        host(~env=dict{"CI": "False"}),
        host(~env=dict{"CI": "1"}),
        host(~env=dict{"CI": "true"}),
        host(~env=dict{"CI": "woodpecker"}),
      ]->Array.map(ciOf),
    ).toEqual([
      Some(false),
      Some(false),
      Some(false),
      Some(false),
      Some(true),
      Some(true),
      Some(true),
    ])
  })

  it("describes a host without anything that identifies it", t => {
    let identifying = host(
      ~env=dict{
        "CI": "true",
        "ENVIO_OPERATOR_URL": "http://example.test",
        "HOSTNAME": "indexer-7f9c4d6b8-xk2p1",
        "INDEXER_ID": "my-indexer",
        "ORGANISATION_ID": "my-org",
        "PWD": "/home/alice/my-indexer",
        "ENVIO_API_TOKEN": "00000000-0000-0000-0000-000000000000",
        "ENVIO_PG_HOST": "db.example.test",
      },
    )

    t.expect(UserAgent.format(~version, identifying->UserAgent.hostFacts)).toBe(
      "hyperindex/1.2.3 (os=linux; arch=x64; node=22; ci=1; env=envio-cloud)",
    )
  })
})
