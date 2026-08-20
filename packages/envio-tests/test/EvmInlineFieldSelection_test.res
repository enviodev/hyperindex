open Vitest

// Registered through a real handler module, which is the only path the inline
// `fields` option takes in a project.

let {config}: InternalTestIndexer.parsed = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: inline-field-selection
field_selection:
  block_fields:
    - miner
  transaction_fields:
    - hash
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
      - event: Approval(address indexed owner, address indexed spender, uint256 value)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
`,
  ~schema=`
type Account {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

// Replaces the config selection: neither \`miner\` nor \`transaction.hash\` is
// readable here, and the fields listed instead are.
indexer.onEvent(
  { contract: "Token", event: "Transfer", fields: { block: ["parentHash"], transaction: ["to"] } },
  async ({ event }) => {
    event.block.parentHash;
    event.transaction.to;
  },
);

// A second handler on the same event, keeping the config selection.
indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event }) => {
  event.block.miner;
  event.transaction.hash;
});

// Merged with the contractRegister below into one registration, which carries
// the union of the two selections.
indexer.onEvent(
  { contract: "Token", event: "Approval", fields: { block: ["stateRoot"] } },
  async ({ event }) => {
    event.block.stateRoot;
  },
);

indexer.contractRegister(
  { contract: "Token", event: "Approval", fields: { transaction: ["gasUsed"] } },
  async ({ event }) => {
    event.transaction.gasUsed;
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { indexer } from "envio";

// Registration is still open here — the suite never builds a test indexer — so
// a rejected selection throws out of \`onEvent\` where it can be asserted.
describe("a rejected inline selection", () => {
  it("names the field, the option and the registration", (t) => {
    t.expect(() =>
      indexer.onEvent(
        { contract: "Token", event: "Transfer", fields: { block: ["notAField" as never] } },
        async () => {},
      ),
    ).toThrowError(
      \`Invalid "notAField" field in the fields.block option of the "Transfer" event registration on contract "Token". Valid block fields: "number", "timestamp", "hash", "parentHash", "nonce", "sha3Uncles", "logsBloom", "transactionsRoot", "stateRoot", "receiptsRoot", "miner", "difficulty", "totalDifficulty", "extraData", "size", "gasLimit", "gasUsed", "uncles", "baseFeePerGas", "blobGasUsed", "excessBlobGas", "parentBeaconBlockRoot", "withdrawalsRoot", "l1BlockNumber", "sendCount", "sendRoot", "mixHash".\`,
    );
  });

  it("rejects a duplicated field name", (t) => {
    t.expect(() =>
      indexer.onEvent(
        { contract: "Token", event: "Transfer", fields: { block: ["parentHash", "parentHash"] } },
        async () => {},
      ),
    ).toThrowError(
      \`Duplicate "parentHash" field in the fields.block option of the "Transfer" event registration on contract "Token".\`,
    );
  });

  it("rejects a selection that isn't an array of names", (t) => {
    t.expect(() =>
      indexer.onEvent(
        { contract: "Token", event: "Transfer", fields: { block: "parentHash" as never } },
        async () => {},
      ),
    ).toThrowError(
      \`The fields.block option of the "Transfer" event registration on contract "Token" must be an array of field names.\`,
    );
  });

  // A plain-JS handler gets no type error for the typo, and an unrecognised key
  // would otherwise read as an empty selection — silently dropping every field
  // config.yaml selected.
  it("rejects a misspelled selection key", (t) => {
    t.expect(() =>
      indexer.onEvent(
        { contract: "Token", event: "Transfer", fields: { blocks: ["parentHash"] } as never },
        async () => {},
      ),
    ).toThrowError(
      \`Invalid "blocks" key in the fields option of the "Transfer" event registration on contract "Token". Valid keys: "block", "transaction".\`,
    );
  });

  it("rejects SVM field-selection keys", (t) => {
    t.expect(() =>
      indexer.onEvent(
        {
          contract: "Token",
          event: "Transfer",
          fields: { instruction: ["args"], accountActivity: ["address"], log: ["kind"] } as never,
        },
        async () => {},
      ),
    ).toThrowError(
      \`Invalid "instruction" key in the fields option of the "Transfer" event registration on contract "Token". Valid keys: "block", "transaction".\`,
    );
  });

  it("rejects a fields option that isn't an object of selections", (t) => {
    t.expect(() =>
      indexer.onEvent(
        { contract: "Token", event: "Transfer", fields: ["parentHash"] as never },
        async () => {},
      ),
    ).toThrowError(
      \`The fields option of the "Transfer" event registration on contract "Token" must be an object of block and transaction field names.\`,
    );
  });
});
`,
)

// A config of its own for each setting the handler module's can't carry at the
// same time: raw events, and an RPC in the chain's source list.
let rawEventsConfig = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: inline-field-selection-raw
raw_events: true
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
`,
).config

let multichainConfig = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: inline-field-selection-multichain
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
  - id: 137
    start_block: 0
    contracts:
      - name: Token
        address: "0x2222222222222222222222222222222222222222"
`,
).config

let rpcConfig = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: inline-field-selection-rpc
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    start_block: 0
    rpc:
      url: "https://rpc.example.test"
      for: fallback
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
`,
).config

let selections = (registrations: HandlerRegister.registrationsByChainId, ~chain="1") => {
  let chainRegistrations: HandlerRegister.chainRegistrations =
    registrations->Utils.Dict.dangerouslyGetNonOption(chain)->Option.getOrThrow
  chainRegistrations.onEventRegistrations->Array.map(reg => (
    reg.fieldSelection.blockFields->Utils.Set.toArray->Array.toSorted(String.compare),
    reg.fieldSelection.transactionFields->Utils.Set.toArray->Array.toSorted(String.compare),
  ))
}

// Registers against a config of its own, so the handler-module registrations
// asserted above have to be read first.
let register = (~config, fn) => {
  HandlerRegister.resetOnEventRegistrations()
  HandlerRegister.startRegistration(~config)
  fn()
  HandlerRegister.finishRegistration(~config)
}

let setHandler = (~fields: option<Internal.evmFieldsSelection>=?, ~where=?, ()) =>
  HandlerRegister.setHandler(
    ~contractName="Token",
    ~eventName="Transfer",
    %raw(`() => Promise.resolve()`),
    ~eventOptions=Some({
      fields: ?fields->Option.map(f => f->(Utils.magic: Internal.evmFieldsSelection => unknown)),
      ?where,
    }),
  )

let setContractRegister = (~fields: option<Internal.evmFieldsSelection>=?, ~where=?, ()) =>
  HandlerRegister.setContractRegister(
    ~contractName="Token",
    ~eventName="Transfer",
    %raw(`() => Promise.resolve()`),
    ~eventOptions=Some({
      fields: ?fields->Option.map(f => f->(Utils.magic: Internal.evmFieldsSelection => unknown)),
      ?where,
    }),
  )

describe("EVM inline field selection", () => {
  it("carries each registration's own selection from the handler module", t => {
    t.expect(HandlerRegister.finishRegistration(~config)->selections).toEqual([
      (["number", "parentHash"], ["to"]),
      (["hash", "miner", "number", "timestamp"], ["hash"]),
      (["number", "stateRoot"], ["gasUsed"]),
    ])
  })

  it("passes each registration's own selection to the source query input", t => {
    let chainRegistrations: HandlerRegister.chainRegistrations =
      HandlerRegister.finishRegistration(~config)
      ->Utils.Dict.dangerouslyGetNonOption("1")
      ->Option.getOrThrow
    let inputs =
      chainRegistrations.onEventRegistrations
      ->(Utils.magic: array<Internal.onEventRegistration> => array<Internal.evmOnEventRegistration>)
      ->HyperSyncClient.Registration.fromOnEventRegistrations
      ->Array.map(
        input => (
          input.blockFields->Array.toSorted(String.compare),
          input.transactionFields->Array.toSorted(String.compare),
        ),
      )
    t.expect(inputs).toEqual([
      (["Number", "ParentHash"], ["To"]),
      (["Hash", "Miner", "Number", "Timestamp"], ["Hash"]),
      (["Number", "StateRoot"], ["GasUsed"]),
    ])
  })

  // `toRawEvent` reads block.hash/block.timestamp off the payload for the
  // `raw_events` row's own columns. They're stripped from the stored
  // `block_fields`, which mirrors the inline selection either way.
  it("keeps block hash and timestamp materialised when the project stores raw events", t => {
    let registrations = register(
      ~config=rawEventsConfig,
      () => setHandler(~fields={block: ["parentHash"]}, ()),
    )
    t.expect(registrations->selections).toEqual([
      (["hash", "number", "parentHash", "timestamp"], []),
    ])
  })

  it("rejects a field an RPC source can't deliver, whatever the RPC syncs for", t => {
    let message = try {
      register(
        ~config=rpcConfig,
        () => setHandler(~fields={transaction: ["accessList"]}, ()),
      )->ignore
      "the registration to fail, but it succeeded"
    } catch {
    | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
    }
    t.expect(
      message,
    ).toBe(`The "accessList" transaction field selected for the "Transfer" event on contract "Token" is unavailable for indexing via RPC. Remove it from the field selection, or remove chain 1's RPC source — even an RPC the chain only falls back to has to deliver the selection.`)
  })

  // A registration resolves for every chain that configures the event, so one
  // chain's set of registrations is rarely the next one's — a `where` can opt a
  // registration out of a chain the others still cover.
  it("gives every chain the selections of the registrations that chain kept", t => {
    let registrations = register(
      ~config=multichainConfig,
      () => {
        setHandler(~fields={transaction: ["to"]}, ~where=%raw(`({chain}) => chain.id === 1`), ())
        setHandler(~fields={block: ["miner"]}, ())
      },
    )
    t.expect((
      registrations->selections,
      registrations->selections(~chain="137"),
    )).toEqual(([(["number"], ["to"]), (["miner", "number"], [])], [(["miner", "number"], [])]))
  })

  // The inline selection resolves once per `onEvent` call and every chain's
  // registration shares it, so a merge (which unions two selections) has to
  // build a new one rather than widen the shared value in place.
  it("keeps a merge on one chain out of the same registration on another", t => {
    let registrations = register(
      ~config=multichainConfig,
      () => {
        setHandler(~fields={block: ["parentHash"]}, ())
        setContractRegister(
          ~fields={transaction: ["gasUsed"]},
          ~where=%raw(`({chain}) => chain.id === 1`),
          (),
        )
      },
    )
    t.expect((
      registrations->selections,
      registrations->selections(~chain="137"),
    )).toEqual((
      [(["number", "parentHash"], ["gasUsed"])],
      [(["number", "parentHash"], [])],
    ))
  })

  // The registration is dropped for this chain before it reaches the source, so
  // the chain's RPC limits never apply to it.
  it("skips the RPC check for a registration whose where opts out of the chain", t => {
    let registrations = register(
      ~config=rpcConfig,
      () => setHandler(~fields={transaction: ["accessList"]}, ~where=%raw(`() => false`), ()),
    )
    t.expect(registrations->selections).toEqual([])
  })
})
