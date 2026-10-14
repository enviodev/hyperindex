// The User-Agent every request to HyperSync carries:
//
//   hyperindex/<version> (os=linux; arch=x64; node=22; ecosystem=evm; storage=postgres; ci=0; env=docker)
//
// Each key is optional and keeps its position, so a reader can split it without
// knowing which release sent it. Every value comes from a fixed list, so it
// describes the kind of setup an indexer runs on and never names a project, a
// host or a path.

type env =
  | @as("envio-cloud") EnvioCloud
  | @as("k8s") Kubernetes
  | @as("docker") Docker
  | @as("local") Local

type storage = {postgres: bool, clickhouse: bool}

type facts = {
  os?: string,
  arch?: string,
  nodeMajor?: int,
  ecosystem?: Ecosystem.name,
  storage?: storage,
  ci?: bool,
  env?: env,
}

// Node's `process.platform` and `process.arch` values. Anything else is left
// out rather than passed through, since it could only have come from somewhere
// other than Node.
let knownOs = [
  "aix",
  "android",
  "cygwin",
  "darwin",
  "freebsd",
  "haiku",
  "linux",
  "netbsd",
  "openbsd",
  "sunos",
  "win32",
]
let knownArch = [
  "arm",
  "arm64",
  "ia32",
  "loong64",
  "mips",
  "mipsel",
  "ppc",
  "ppc64",
  "riscv64",
  "s390",
  "s390x",
  "x64",
]

let storageValue = ({postgres, clickhouse}) =>
  switch [
    postgres ? Some("postgres") : None,
    clickhouse ? Some("clickhouse") : None,
  ]->Array.keepSome {
  | [] => None
  | sinks => Some(sinks->Array.join("+"))
  }

let format = (~version, facts: facts) => {
  let fields =
    [
      ("os", facts.os->Option.filter(os => knownOs->Array.includes(os))),
      ("arch", facts.arch->Option.filter(arch => knownArch->Array.includes(arch))),
      ("node", facts.nodeMajor->Option.filter(major => major > 0)->Option.map(Int.toString(_))),
      ("ecosystem", facts.ecosystem->Option.map(name => (name :> string))),
      ("storage", facts.storage->Option.flatMap(storageValue)),
      ("ci", facts.ci->Option.map(ci => ci ? "1" : "0")),
      ("env", facts.env->Option.map(env => (env :> string))),
    ]->Array.filterMap(((key, value)) => value->Option.map(value => `${key}=${value}`))
  switch fields {
  | [] => `hyperindex/${version}`
  | _ => `hyperindex/${version} (${fields->Array.join("; ")})`
  }
}

type host = {
  platform: string,
  arch: string,
  nodeVersion: string,
  env: dict<string>,
  hasDockerEnv: bool,
}

let hostFacts = (host: host): facts => {
  let isSet = name =>
    switch host.env->Dict.get(name) {
    | None | Some("") => false
    | Some(_) => true
    }
  {
    os: host.platform,
    arch: host.arch,
    nodeMajor: ?(
      host.nodeVersion->String.split(".")->Array.get(0)->Option.flatMap(Int.fromString(_))
    ),
    ci: switch host.env->Dict.get("CI")->Option.map(String.toLowerCase) {
    | None | Some("" | "0" | "false") => false
    | Some(_) => true
    },
    // Envio Cloud sets ENVIO_OPERATOR_URL on every indexer it runs. It runs
    // them on Kubernetes, and Kubernetes runs containers, so the most specific
    // match has to be checked first.
    env: if isSet("ENVIO_OPERATOR_URL") {
      EnvioCloud
    } else if isSet("KUBERNETES_SERVICE_HOST") {
      Kubernetes
    } else if host.hasDockerEnv {
      Docker
    } else {
      Local
    },
  }
}

@val external processNodeVersion: string = "process.versions.node"

let currentHost = (): host => {
  platform: Core.processPlatform,
  arch: Core.processArch,
  nodeVersion: processNodeVersion,
  env: NodeJs.Process.process.env,
  hasDockerEnv: NodeJs.Fs.existsSync("/.dockerenv"),
}

%%private(let processFacts = currentHost()->hostFacts)

%%private(let version = Utils.EnvioPackage.value.version)

%%private(let current = ref(format(~version, processFacts)))

let prime = (~ecosystem, ~storage) =>
  current := format(~version, {...processFacts, ecosystem, storage})

let get = () => current.contents
