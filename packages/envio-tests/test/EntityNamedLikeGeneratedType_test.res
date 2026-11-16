// https://github.com/enviodev/hyperindex/issues/1808
// Entity aliases are exported from inside `declare module "envio"`, where an
// export wins over a file-level type of the same name. No name a schema can
// use may change what an event's block or transaction resolves to.
open Vitest

describe("an entity named like a generated type", () => {
  it("leaves event block, transaction and entity types intact", _ =>
    InternalTestIndexer.fromUserApi(
      ~configYaml=`
name: generated-type-names
field_selection:
  transaction_fields:
    - hash
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
        events:
          - event: Transfer(address indexed to, uint256 value)
`,
      ~schema=`
enum Status {
  ACTIVE
}
type EvmTransaction {
  id: ID!
}
type Entities {
  id: ID!
  status: Status!
}
type Enums {
  id: ID!
}
`,
      ~handlers=`
import type { Entity, Enum, EvmEvent } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

type TransferEvent = EvmEvent<"Token", "Transfer">;
expectType<
  TypeEqual<
    [
      TransferEvent["block"]["number"],
      TransferEvent["transaction"]["hash"],
      Entity<"EvmTransaction">,
      Entity<"Entities">,
      Enum<"Status">,
    ],
    [number, string, { readonly id: string }, { readonly id: string; readonly status: "ACTIVE" }, "ACTIVE"]
  >
>(true);
`,
    )->ignore
  )
})
