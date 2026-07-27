open Vitest

// Every Sway log shape the ABI decoder produces, pinned against the TypeScript
// `event.params` the config's generated types hand a handler. The
// `S.assertOrThrow` calls tie each rescript-schema shape to the generated param
// type, so a decoder change breaks the type-check here.
let files = Dict.fromArray([("abis/all-events-abi.json", FuelAbiFixtures.allEvents)])

let configYaml = `
name: fuel-sway-types
ecosystem: fuel
chains:
  - id: 0
    start_block: 0
    contracts:
      - name: AllEvents
        address: 0xd298efffbf3cdf38b4b55ffe76a97a67b9146d7edd61b92cca730bd6e0eb415d
        abi_file_path: abis/all-events-abi.json
        events:
          - name: UnitLog
            logId: "3330666440490685604"
          - name: Option_
            logId: "10927802446890217233"
          - name: SimpleStructWithOptionalField
            logId: "3525891009499019808"
          - name: U8Log
            logId: "14454674236531057292"
          - name: ArrayLog
            logId: "12456997331598520636"
          - name: Result
            logId: "499881700873475792"
          - name: U64Log
            logId: "1515152261580153489"
          - name: B256Log
            logId: "8961848586872524460"
          - name: U32Log
            logId: "15520703124961489725"
          - name: Status
            logId: "7417129983252335614"
          - name: U16Log
            logId: "2992671284987479467"
          - name: TupleLog
            logId: "6486780880364592010"
          - name: SimpleStruct
            logId: "8500535089865083573"
          - name: UnknownLog
            logId: "1970142151624111756"
          - name: BoolLog
            logId: "13213829929622723620"
          - name: StrLog
            logId: "10732353433239600734"
          - name: StringLog
            logId: "11132648958528852192"
          - name: Option2
            logId: "8688528864679113840"
          - name: VecLog
            logId: "15402277555065905665"
          - name: TagsEvent
            logId: "8843604259160078410"
          - name: BytesLog
            logId: "14832741149864513620"
          - name: Mint
          - name: Burn
          - name: Transfer
`

let check = handlers =>
  InternalTestIndexer.fromUserApi(
    ~schema=ApiTypesFixtures.schema,
    ~files,
    ~handlers,
    ~configYaml,
  )->ignore

let preamble = `
import { S, indexer } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

type RemoveReadonly<T> = T extends {}
  ? { -readonly [key in keyof T]: RemoveReadonly<T[key]> }
  : T;

type AssertSchemaType<Target, Schema> = TypeEqual<
  RemoveReadonly<Target>,
  S.Output<Schema>
>;

const SExtra = {
  void: S.schema(undefined) as S.Schema<undefined, undefined>,
  swayOptional: <T>(schema: S.Schema<T>) =>
    S.union([
      { case: "None" as const, payload: SExtra.void },
      { case: "Some" as const, payload: schema },
    ]),
  swayResult: <T, E>(ok: S.Schema<T>, err: S.Schema<E>) =>
    S.union([
      { case: "Ok" as const, payload: ok },
      { case: "Err" as const, payload: err },
    ]),
};
`

// Each entry asserts one log's decoded \`params\` against a rescript-schema shape.
let assertParams = (~event, ~schema, ~wildcard=false) => {
  let options = wildcard
    ? `{ contract: "AllEvents", event: "${event}", wildcard: true }`
    : `{ contract: "AllEvents", event: "${event}" }`
  `
const schema_${event} = ${schema};
indexer.onEvent(${options}, async ({ event }) => {
  S.assertOrThrow(event.params, schema_${event})!;
  expectType<AssertSchemaType<typeof event.params, typeof schema_${event}>>(true);
});
`
}

describe("Fuel Sway log types", () => {
  it("decodes primitive logs to their TypeScript counterparts", _ =>
    check(
      preamble ++
      assertParams(~event="UnitLog", ~schema="SExtra.void") ++
      assertParams(~event="U8Log", ~schema="S.number") ++
      assertParams(~event="U16Log", ~schema="S.number") ++
      assertParams(~event="U32Log", ~schema="S.number") ++
      assertParams(~event="U64Log", ~schema="S.bigint") ++
      assertParams(~event="B256Log", ~schema="S.string") ++
      assertParams(~event="StringLog", ~schema="S.string") ++
      assertParams(~event="UnknownLog", ~schema="S.bigint") ++
      assertParams(~event="BytesLog", ~schema="S.unknown") ++
      assertParams(~event="BoolLog", ~schema="S.boolean", ~wildcard=true) ++
      assertParams(~event="StrLog", ~schema="S.string", ~wildcard=true),
    )
  )

  it("decodes container logs — arrays, vecs and tuples", _ =>
    check(
      preamble ++
      assertParams(~event="ArrayLog", ~schema="S.array(S.number)") ++
      assertParams(~event="VecLog", ~schema="S.array(S.bigint)") ++
      assertParams(~event="TupleLog", ~schema="S.schema([S.bigint, S.boolean])"),
    )
  )

  it("decodes Option and Result enums, including nesting", _ =>
    check(
      preamble ++
      assertParams(~event="Option_", ~schema="SExtra.swayOptional(S.number)") ++
      assertParams(
        ~event="Option2",
        ~schema="SExtra.swayOptional(SExtra.swayOptional(S.number))",
      ) ++
      assertParams(~event="Result", ~schema="SExtra.swayResult(S.number, S.boolean)"),
    )
  )

  it("decodes structs and payload-carrying enums", _ =>
    check(
      preamble ++
      assertParams(~event="SimpleStruct", ~schema="S.schema({ f1: S.number })") ++
      assertParams(
        ~event="SimpleStructWithOptionalField",
        ~schema="S.schema({ f1: S.number, f2: SExtra.swayOptional(S.number) })",
      ) ++
      assertParams(
        ~event="TagsEvent",
        ~schema="S.schema({ tags: SExtra.swayOptional(S.array(S.string)) })",
      ) ++
      assertParams(
        ~event="Status",
        ~schema=`S.union([
  { case: "Pending" as const, payload: SExtra.void },
  { case: "Completed" as const, payload: S.number },
  { case: "Failed" as const, payload: { reason: S.number } },
])`,
      ),
    )
  )

  // Receipt-backed events carry no logId — their params come from the receipt
  // shape rather than the ABI's logged types.
  it("decodes Mint, Burn and Transfer receipts", _ =>
    check(
      preamble ++
      assertParams(~event="Mint", ~schema="S.schema({ subId: S.string, amount: S.bigint })") ++
      assertParams(~event="Burn", ~schema="S.schema({ subId: S.string, amount: S.bigint })") ++
      assertParams(
        ~event="Transfer",
        ~schema="S.schema({ assetId: S.string, to: S.address, amount: S.bigint })",
      ),
    )
  )
})
