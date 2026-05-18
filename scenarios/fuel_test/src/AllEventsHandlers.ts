/*
 * Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features
 */
import { S } from "envio";
import { indexer } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

type RemoveReadonly<T> = T extends {}
  ? {
      -readonly [key in keyof T]: RemoveReadonly<T[key]>;
    }
  : T;

type AssertSchemaType<Target, Schema> = TypeEqual<
  RemoveReadonly<Target>,
  S.Output<Schema>
>;

const SExtra = {
  void: S.schema(undefined) as S.Schema<undefined, undefined>,
  swayOptional: <T>(schema: S.Schema<T>) =>
    S.union([
      {
        case: "None" as const,
        payload: SExtra.void,
      },
      {
        case: "Some" as const,
        payload: schema,
      },
    ]),
  swayResult: <T, E>(ok: S.Schema<T>, err: S.Schema<E>) =>
    S.union([
      {
        case: "Ok" as const,
        payload: ok,
      },
      {
        case: "Err" as const,
        payload: err,
      },
    ]),
};

const unitLogSchema = SExtra.void;
indexer.onEvent({ contract: "AllEvents", event: "UnitLog" },async ({ event }) => {
  S.assertOrThrow(event.params, unitLogSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof unitLogSchema>>(true);
});

const optionLogSchema = SExtra.swayOptional(S.number);
// Add underscore here, because otherwise ReScript adds $$ which breaks runtime
indexer.onEvent({ contract: "AllEvents", event: "Option_" },async ({ event }) => {
  S.assertOrThrow(event.params, optionLogSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof optionLogSchema>>(
    true
  );
});

const simpleStructWithOptionalSchema = S.schema({
  f1: S.number,
  f2: SExtra.swayOptional(S.number),
});
indexer.onEvent({ contract: "AllEvents", event: "SimpleStructWithOptionalField" },async ({ event }) => {
  S.assertOrThrow(event.params, simpleStructWithOptionalSchema)!;
  expectType<
    AssertSchemaType<typeof event.params, typeof simpleStructWithOptionalSchema>
  >(true);
});

const u8LogSchema = S.number;
indexer.onEvent({ contract: "AllEvents", event: "U8Log" },async ({ event }) => {
  S.assertOrThrow(event.params, u8LogSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof u8LogSchema>>(true);
});

const u16LogSchema = S.number;
indexer.onEvent({ contract: "AllEvents", event: "U16Log" },async ({ event }) => {
  S.assertOrThrow(event.params, u16LogSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof u16LogSchema>>(true);
});

const u32LogSchema = S.number;
indexer.onEvent({ contract: "AllEvents", event: "U32Log" },async ({ event }) => {
  S.assertOrThrow(event.params, u32LogSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof u32LogSchema>>(true);
});

const u64LogSchema = S.bigint;
indexer.onEvent({ contract: "AllEvents", event: "U64Log" },async ({ event }) => {
  S.assertOrThrow(event.params, u64LogSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof u64LogSchema>>(true);
});

const b256LogSchema = S.string;
indexer.onEvent({ contract: "AllEvents", event: "B256Log" },async ({ event }) => {
  S.assertOrThrow(event.params, b256LogSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof b256LogSchema>>(true);
});

const arrayLogSchema = S.array(S.number);
indexer.onEvent({ contract: "AllEvents", event: "ArrayLog" },async ({ event }) => {
  S.assertOrThrow(event.params, arrayLogSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof arrayLogSchema>>(
    true
  );
});

const resultLogSchema = SExtra.swayResult(S.number, S.boolean);
indexer.onEvent({ contract: "AllEvents", event: "Result" },async ({ event }) => {
  S.assertOrThrow(event.params, resultLogSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof resultLogSchema>>(
    true
  );
});

const statusSchema = S.union([
  {
    case: "Pending" as const,
    payload: SExtra.void,
  },
  {
    case: "Completed" as const,
    payload: S.number,
  },
  {
    case: "Failed" as const,
    payload: {
      reason: S.number,
    },
  },
]);
indexer.onEvent({ contract: "AllEvents", event: "Status" },async ({ event }) => {
  S.assertOrThrow(event.params, statusSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof statusSchema>>(true);
});

const tupleLogSchema = S.schema([S.bigint, S.boolean]);
indexer.onEvent({ contract: "AllEvents", event: "TupleLog" },async ({ event }) => {
  S.assertOrThrow(event.params, tupleLogSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof tupleLogSchema>>(
    true
  );
});

const simpleStructSchema = S.schema({
  f1: S.number,
});
indexer.onEvent({ contract: "AllEvents", event: "SimpleStruct" },async ({ event }) => {
  S.assertOrThrow(event.params, simpleStructSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof simpleStructSchema>>(
    true
  );
});

const unknownLogSchema = S.bigint;
indexer.onEvent({ contract: "AllEvents", event: "UnknownLog" },async ({ event }) => {
  S.assertOrThrow(event.params, unknownLogSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof unknownLogSchema>>(
    true
  );
});

const boolLogSchema = S.boolean;
indexer.onEvent({ contract: "AllEvents", event: "BoolLog", wildcard: true },
  async ({ event }) => {
    S.assertOrThrow(event.params, boolLogSchema)!;
    expectType<AssertSchemaType<typeof event.params, typeof boolLogSchema>>(
      true
    );
  },
);

const strLogSchema = S.string;
indexer.onEvent({ contract: "AllEvents", event: "StrLog", wildcard: true },
  async ({ event }) => {
    S.assertOrThrow(event.params, strLogSchema)!;
    expectType<AssertSchemaType<typeof event.params, typeof strLogSchema>>(
      true
    );
  },
);

const stringLogSchema = S.string;
indexer.onEvent({ contract: "AllEvents", event: "StringLog" },async ({ event }) => {
  S.assertOrThrow(event.params, stringLogSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof stringLogSchema>>(
    true
  );
});

const option2LogSchema = SExtra.swayOptional(SExtra.swayOptional(S.number));
indexer.onEvent({ contract: "AllEvents", event: "Option2" },async ({ event }) => {
  S.assertOrThrow(event.params, option2LogSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof option2LogSchema>>(
    true
  );
});

const vecLogSchema = S.array(S.bigint);
indexer.onEvent({ contract: "AllEvents", event: "VecLog" },async ({ event }) => {
  S.assertOrThrow(event.params, vecLogSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof vecLogSchema>>(true);
});

const bytesLogSchema = S.unknown;
indexer.onEvent({ contract: "AllEvents", event: "BytesLog" },async ({ event }) => {
  S.assertOrThrow(event.params, bytesLogSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof bytesLogSchema>>(
    true
  );
});

const mintSchema = S.schema({
  subId: S.string,
  amount: S.bigint,
});
indexer.onEvent({ contract: "AllEvents", event: "Mint" },async ({ event }) => {
  S.assertOrThrow(event.params, mintSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof mintSchema>>(true);
});

const burnSchema = S.schema({
  subId: S.string,
  amount: S.bigint,
});
indexer.onEvent({ contract: "AllEvents", event: "Burn" },async ({ event }) => {
  S.assertOrThrow(event.params, burnSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof burnSchema>>(true);
});

const transferOutSchema = S.schema({
  assetId: S.string,
  to: S.address,
  amount: S.bigint,
});
indexer.onEvent({ contract: "AllEvents", event: "Transfer" },async ({ event }) => {
  S.assertOrThrow(event.params, transferOutSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof transferOutSchema>>(
    true
  );
});

const tagsEventSchema = S.schema({
  tags: SExtra.swayOptional(S.array(S.string)),
});
indexer.onEvent({ contract: "AllEvents", event: "TagsEvent" },async ({ event }) => {
  S.assertOrThrow(event.params, tagsEventSchema)!;
  expectType<AssertSchemaType<typeof event.params, typeof tagsEventSchema>>(
    true
  );
});

// const callSchema = S.schema({
//   assetId: S.string,
//   to: S.string,
//   amount: S.bigint,
// });
// indexer.onEvent({ contract: "AllEvents", event: "Call" },
//   async ({ event }) => {
//     S.assertOrThrow(event.params,callSchema)!;
//     expectType<AssertSchemaType<typeof event.params, typeof callSchema>>(true);
//   }
//   { wildcard: true }
// );
