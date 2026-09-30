open Vitest

// What a restart does with a config.yaml or schema edited since the database
// was built. The one migration applied in place is a chain added under
// `envio start --chain`; every other change to what the database holds is
// refused and needs a resync. What config.yaml owns but the database doesn't —
// sources, block lag, a contract's start block — is read on every start.

let schema = `
type Counter {
  id: ID!
  count: BigInt!
}
`

let address = n => `0x000000000000000000000000000000000000000${n->Int.toString}`

let chain = (
  id,
  ~startBlock="1",
  ~endBlock=?,
  ~maxReorgDepth=?,
  ~blockLag=?,
  ~rpc="https://rpc.example.test",
  ~contract="Token",
  ~addresses=[address(1)],
  ~contractStartBlock=?,
) => {
  let optional = (key, value) =>
    value->Option.mapOr("", value => `\n    ${key}: ${value->Int.toString}`)
  `
  - id: ${id->Int.toString}
    rpc:
      url: ${rpc}
      for: sync
    start_block: ${startBlock}${optional("end_block", endBlock)}${optional(
      "max_reorg_depth",
      maxReorgDepth,
    )}${optional("block_lag", blockLag)}
    contracts:
      - name: ${contract}
        address: [${addresses
    ->Array.map(address => `"${address}"`)
    ->Array.join(", ")}]${contractStartBlock->Option.mapOr("", startBlock =>
      `\n        start_block: ${startBlock->Int.toString}`
    )}
`
}

let deployment = (~name="migration", ~chains, ~contracts=["Token"], ~schema=schema) =>
  Scenario.make(
    ~schema,
    ~configYaml=`
name: ${name}
disable_default_cross_chain: true
contracts:${contracts
      ->Array.map(contract =>
        `
  - name: ${contract}
    events:
      - event: Transfer()`
      )
      ->Array.join("")}
chains:${chains->Array.join("")}`,
  )

let deployed = deployment(~chains=[chain(1)])

describe("Resuming a chain against the stored config", () => {
  Migration.it(
    "Resumes an unchanged config",
    ~deployed,
    ~edited=deployment(~chains=[chain(1)]),
    ~expected=Resumed([1]),
  )

  Migration.it(
    "Resumes when only how the chain is reached or paced changed",
    ~deployed,
    ~edited=deployment(~chains=[chain(1, ~rpc="https://other-rpc.example.test", ~blockLag=5)]),
    ~expected=Resumed([1]),
  )

  // Not stored: after the first sync it only filters addresses registered from
  // then on.
  Migration.it(
    "Resumes when a contract's start block changed",
    ~deployed,
    ~edited=deployment(~chains=[chain(1, ~contractStartBlock=50)]),
    ~expected=Resumed([1]),
  )

  // `latest` is whatever it resolved to when the chain was first stored.
  Migration.it(
    "Resumes when a start block became latest",
    ~deployed,
    ~edited=deployment(~chains=[chain(1, ~startBlock="latest")]),
    ~expected=Resumed([1]),
  )

  Migration.it(
    "Refuses a changed start block",
    ~deployed,
    ~edited=deployment(~chains=[chain(1, ~startBlock="2")]),
    ~expected=Refused(["evm.chains.1.startBlock"]),
  )

  Migration.it(
    "Refuses an added end block",
    ~deployed,
    ~edited=deployment(~chains=[chain(1, ~endBlock=1000)]),
    ~expected=Refused(["evm.chains.1.endBlock"]),
  )

  Migration.it(
    "Refuses a changed end block",
    ~deployed=deployment(~chains=[chain(1, ~endBlock=1000)]),
    ~edited=deployment(~chains=[chain(1, ~endBlock=2000)]),
    ~expected=Refused(["evm.chains.1.endBlock"]),
  )

  Migration.it(
    "Refuses a changed max reorg depth",
    ~deployed,
    ~edited=deployment(~chains=[chain(1, ~maxReorgDepth=10)]),
    ~expected=Refused(["evm.chains.1.maxReorgDepth"]),
  )

  Migration.it(
    "Refuses an added address, naming it",
    ~deployed,
    ~edited=deployment(~chains=[chain(1, ~addresses=[address(1), address(2)])]),
    ~expected=Refused([`evm.chains.1.contracts.Token.addresses.${address(2)}`]),
  )

  Migration.it(
    "Refuses a removed address, naming it",
    ~deployed=deployment(~chains=[chain(1, ~addresses=[address(1), address(2)])]),
    ~edited=deployment(~chains=[chain(1)]),
    ~expected=Refused([`evm.chains.1.contracts.Token.addresses.${address(2)}`]),
  )

  Migration.it(
    "Refuses an added entity",
    ~deployed,
    ~edited=deployment(~chains=[chain(1)], ~schema=schema ++ "\ntype Extra {\n  id: ID!\n}\n"),
    ~expected=Refused(["entities[1]"]),
  )

  Migration.it(
    "Refuses a renamed indexer",
    ~deployed,
    ~edited=deployment(~name="renamed", ~chains=[chain(1)]),
    ~expected=Refused(["name"]),
  )
})

describe("Changing the chains of a deployment", () => {
  let withChain137 = deployment(~chains=[chain(1), chain(137)])

  Migration.it(
    "Adds a new chain that envio start --chain names alone",
    ~deployed,
    ~edited=withChain137,
    ~chains=[137],
    ~expected=Resumed([1, 137]),
  )

  Migration.it(
    "Leaves a new chain to its own process",
    ~deployed,
    ~edited=withChain137,
    ~chains=[1],
    ~expected=Resumed([1]),
  )

  Migration.it(
    "Refuses a new chain in a run that doesn't name it alone",
    ~deployed,
    ~edited=withChain137,
    ~expected=Refused(["evm.chains.137"]),
  )

  Migration.it(
    "Refuses two new chains in one process",
    ~deployed,
    ~edited=deployment(~chains=[chain(1), chain(10), chain(137)]),
    ~chains=[10, 137],
    ~expected=Refused(["evm.chains.10", "evm.chains.137"]),
  )

  Migration.it(
    "Refuses a new chain that brings a new contract",
    ~deployed,
    ~edited=deployment(
      ~chains=[chain(1), chain(137, ~contract="Vault")],
      ~contracts=["Token", "Vault"],
    ),
    ~chains=[137],
    ~expected=Refused(["evm.contracts.Vault", "contracts"]),
  )

  Migration.it(
    "Refuses a new chain alongside another change",
    ~deployed,
    ~edited=deployment(
      ~chains=[chain(1), chain(137)],
      ~schema=schema ++ "\ntype Extra {\n  id: ID!\n}\n",
    ),
    ~chains=[137],
    ~expected=Refused(["entities[1]"]),
  )

  Migration.it(
    "Refuses a dropped chain",
    ~deployed=withChain137,
    ~edited=deployed,
    ~expected=Refused(["evm.chains.137"]),
  )

  // A process answers for its own chains: the one whose settings changed is
  // refused by the process that drives it.
  let with137Moved = deployment(~chains=[chain(1), chain(137, ~startBlock="2")])

  Migration.it(
    "Resumes a chain's process while another chain's settings changed",
    ~deployed=withChain137,
    ~edited=with137Moved,
    ~chains=[1],
    ~expected=Resumed([1, 137]),
  )

  Migration.it(
    "Refuses the changed chain's own process",
    ~deployed=withChain137,
    ~edited=with137Moved,
    ~chains=[137],
    ~expected=Refused(["evm.chains.137.startBlock"]),
  )
})
