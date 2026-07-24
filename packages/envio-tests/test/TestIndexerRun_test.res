open Vitest

// Runs handler source in-process against an isolated per-instance registration,
// then drives the in-memory test indexer over simulate items.

let configYaml = `
name: internal-test
chains:
  - id: 1
    rpc:
      url: https://eth.com
      for: sync
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`

let schema = `
type Account {
  id: ID!
  balance: BigInt!
}
`

let zero = Address.unsafeFromString("0x0000000000000000000000000000000000000000")
let holder = Address.unsafeFromString("0x0000000000000000000000000000000000000002")

let transferItem: Envio.evmSimulateItem = {
  contract: "Token",
  event: "Transfer",
  params: {"from": zero, "to": holder, "value": 5n}->(Utils.magic: {..} => JSON.t),
}

// One change checkpoint carrying the entity `sets` recorded for it.
type change = {
  block: int,
  chainId: int,
  eventsProcessed: int,
  @as("Account") account: {"sets": array<{"id": string, "balance": bigint}>},
}

let processOnce = (indexer: TestIndexer.t<_>) =>
  indexer.process({
    "chains": {
      "1": {"startBlock": 1, "endBlock": 100, "simulate": [transferItem]},
    },
  })

let handlersSettingBalance = balance => `
import { indexer } from "envio";
indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  context.Account.set({ id: "acc-1", balance: ${balance} });
});
`

describe("InternalTestIndexer.createTestIndexer", () => {
  Async.it("runs a handler from the source string over simulate items", async t => {
    let {createTestIndexer} = InternalTestIndexer.fromUserApi(
      ~schema,
      ~handlers=handlersSettingBalance("event.params.value"),
      ~configYaml,
    )
    let indexer = await createTestIndexer()
    let result = await processOnce(indexer)

    t.expect(result.changes->(Utils.magic: array<unknown> => array<change>)).toEqual([
      {
        block: 1,
        chainId: 1,
        eventsProcessed: 1,
        account: {"sets": [{"id": "acc-1", "balance": 5n}]},
      },
    ])
  })

  Async.it("keeps registrations isolated between instances", async t => {
    let a = InternalTestIndexer.fromUserApi(
      ~schema,
      ~handlers=handlersSettingBalance("1n"),
      ~configYaml,
    )
    let b = InternalTestIndexer.fromUserApi(
      ~schema,
      ~handlers=handlersSettingBalance("2n"),
      ~configYaml,
    )

    let indexerA = await a.createTestIndexer()
    let indexerB = await b.createTestIndexer()

    let resultA = await processOnce(indexerA)
    let resultB = await processOnce(indexerB)

    t.expect({
      "a": resultA.changes->(Utils.magic: array<unknown> => array<change>),
      "b": resultB.changes->(Utils.magic: array<unknown> => array<change>),
    }).toEqual({
      "a": [
        {
          block: 1,
          chainId: 1,
          eventsProcessed: 1,
          account: {"sets": [{"id": "acc-1", "balance": 1n}]},
        },
      ],
      "b": [
        {
          block: 1,
          chainId: 1,
          eventsProcessed: 1,
          account: {"sets": [{"id": "acc-1", "balance": 2n}]},
        },
      ],
    })
  })

  Async.it("re-imports handlers on every createTestIndexer call", async t => {
    let {createTestIndexer} = InternalTestIndexer.fromUserApi(
      ~schema,
      ~handlers=handlersSettingBalance("event.params.value"),
      ~configYaml,
    )
    let first = await createTestIndexer()
    let second = await createTestIndexer()

    let resultFirst = await processOnce(first)
    let resultSecond = await processOnce(second)

    let expected: array<change> = [
      {
        block: 1,
        chainId: 1,
        eventsProcessed: 1,
        account: {"sets": [{"id": "acc-1", "balance": 5n}]},
      },
    ]
    t.expect({
      "first": resultFirst.changes->(Utils.magic: array<unknown> => array<change>),
      "second": resultSecond.changes->(Utils.magic: array<unknown> => array<change>),
    }).toEqual({"first": expected, "second": expected})
  })

  Async.it("throws when a handler registers for an unconfigured event", async t => {
    // `any` slips past the type-check harness so the runtime scope guard is what
    // rejects the unknown event.
    let {createTestIndexer} = InternalTestIndexer.fromUserApi(
      ~schema,
      ~handlers=`
import { indexer } from "envio";
const badId: any = { contract: "Token", event: "DoesNotExist" };
indexer.onEvent(badId, async () => {});
`,
      ~configYaml,
    )
    let message = try {
      let _ = await createTestIndexer()
      "expected createTestIndexer to throw, but it resolved"
    } catch {
    | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
    }
    t.expect(message).toContain(`No event "DoesNotExist" is configured on contract "Token"`)
  })
})
