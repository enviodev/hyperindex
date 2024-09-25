/*
 * Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features
 */
import { AllEvents } from "generated";
import { expectType, TypeEqual } from "ts-expect";
import * as S from "rescript-schema";

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
  void: S.undefined as S.Schema<void>,
  swayOptional: <T>(schema: S.Schema<T>) =>
    S.union([
      S.object({
        case: "None" as const,
        payload: SExtra.void,
      }),
      S.object({
        case: "Some" as const,
        payload: schema,
      }),
    ]),
  swayResult: <T, E>(ok: S.Schema<T>, err: S.Schema<E>) =>
    S.union([
      S.object({
        case: "Ok" as const,
        payload: ok,
      }),
      S.object({
        case: "Err" as const,
        payload: err,
      }),
    ]),
  bigint: S.custom("BigInt", (unknown, s) => {
    if (typeof unknown === "bigint") {
      return unknown;
    }
    throw s.fail("Expected bigint");
  }),
};

const unitLogSchema = SExtra.void;
AllEvents.UnitLog.handler(async ({ event }) => {
  unitLogSchema.assert(event.params)!;
  expectType<AssertSchemaType<typeof event.params, typeof unitLogSchema>>(true);
});

const optionLogSchema = SExtra.swayOptional(S.number);
// Add underscore here, because otherwise ReScript adds $$ which breaks runtime
AllEvents.Option_.handler(async ({ event }) => {
  optionLogSchema.assert(event.params)!;
  expectType<AssertSchemaType<typeof event.params, typeof optionLogSchema>>(
    true
  );
});

const simpleStructWithOptionalSchema = S.object({
  f1: S.number,
  f2: SExtra.swayOptional(S.number),
});
AllEvents.SimpleStructWithOptionalField.handler(async ({ event }) => {
  simpleStructWithOptionalSchema.assert(event.params)!;
  expectType<
    AssertSchemaType<typeof event.params, typeof simpleStructWithOptionalSchema>
  >(true);
});

const u8LogSchema = S.number;
AllEvents.U8Log.handler(async ({ event }) => {
  u8LogSchema.assert(event.params)!;
  expectType<AssertSchemaType<typeof event.params, typeof u8LogSchema>>(true);
});

const u16LogSchema = S.number;
AllEvents.U16Log.handler(async ({ event }) => {
  u16LogSchema.assert(event.params)!;
  expectType<AssertSchemaType<typeof event.params, typeof u16LogSchema>>(true);
});

const u32LogSchema = S.number;
AllEvents.U32Log.handler(async ({ event }) => {
  u32LogSchema.assert(event.params)!;
  expectType<AssertSchemaType<typeof event.params, typeof u32LogSchema>>(true);
});

const u64LogSchema = SExtra.bigint;
AllEvents.U64Log.handler(async ({ event }) => {
  u64LogSchema.assert(event.params)!;
  expectType<AssertSchemaType<typeof event.params, typeof u64LogSchema>>(true);
});

const b256LogSchema = S.string;
AllEvents.B256Log.handler(async ({ event }) => {
  b256LogSchema.assert(event.params)!;
  expectType<AssertSchemaType<typeof event.params, typeof b256LogSchema>>(true);
});

const arrayLogSchema = S.array(S.number);
AllEvents.ArrayLog.handler(async ({ event }) => {
  arrayLogSchema.assert(event.params)!;
  expectType<AssertSchemaType<typeof event.params, typeof arrayLogSchema>>(
    true
  );
});

const resultLogSchema = SExtra.swayResult(S.number, S.boolean);
AllEvents.Result.handler(async ({ event }) => {
  resultLogSchema.assert(event.params)!;
  expectType<AssertSchemaType<typeof event.params, typeof resultLogSchema>>(
    true
  );
});

const statusSchema = S.union([
  S.object({
    case: "Pending" as const,
    payload: SExtra.void,
  }),
  S.object({
    case: "Completed" as const,
    payload: S.number,
  }),
  S.object({
    case: "Failed" as const,
    payload: S.object({
      reason: S.number,
    }),
  }),
]);
AllEvents.Status.handler(async ({ event }) => {
  statusSchema.assert(event.params)!;
  expectType<AssertSchemaType<typeof event.params, typeof statusSchema>>(true);
});

const tupleLogSchema = S.tuple([SExtra.bigint, S.boolean]);
AllEvents.TupleLog.handler(async ({ event }) => {
  tupleLogSchema.assert(event.params)!;
  expectType<AssertSchemaType<typeof event.params, typeof tupleLogSchema>>(
    true
  );
});

const simpleStructSchema = S.object({
  f1: S.number,
});
AllEvents.SimpleStruct.handler(async ({ event }) => {
  simpleStructSchema.assert(event.params)!;
  expectType<AssertSchemaType<typeof event.params, typeof simpleStructSchema>>(
    true
  );
});

const unknownLogSchema = SExtra.bigint;
AllEvents.UnknownLog.handler(async ({ event }) => {
  unknownLogSchema.assert(event.params)!;
  expectType<AssertSchemaType<typeof event.params, typeof unknownLogSchema>>(
    true
  );
});

const boolLogSchema = S.boolean;
AllEvents.BoolLog.handler(
  async ({ event }) => {
    boolLogSchema.assert(event.params)!;
    expectType<AssertSchemaType<typeof event.params, typeof boolLogSchema>>(
      true
    );
  },
  { wildcard: true }
);

const strLogSchema = S.string;
AllEvents.StrLog.handler(
  async ({ event }) => {
    strLogSchema.assert(event.params)!;
    expectType<AssertSchemaType<typeof event.params, typeof strLogSchema>>(
      true
    );
  },
  { wildcard: true }
);

const option2LogSchema = SExtra.swayOptional(SExtra.swayOptional(S.number));
AllEvents.Option2.handler(async ({ event }) => {
  option2LogSchema.assert(event.params)!;
  expectType<AssertSchemaType<typeof event.params, typeof option2LogSchema>>(
    true
  );
});

const vecLogSchema = S.array(SExtra.bigint);
AllEvents.VecLog.handler(async ({ event }) => {
  vecLogSchema.assert(event.params)!;
  expectType<AssertSchemaType<typeof event.params, typeof vecLogSchema>>(true);
});

const bytesLogSchema = S.unknown;
AllEvents.BytesLog.handler(async ({ event }) => {
  bytesLogSchema.assert(event.params)!;
  expectType<AssertSchemaType<typeof event.params, typeof bytesLogSchema>>(
    true
  );
});

const mintSchema = S.object({
  subId: S.string,
  amount: SExtra.bigint,
});
AllEvents.Mint.handler(async ({ event }) => {
  mintSchema.assert(event.params)!;
  expectType<AssertSchemaType<typeof event.params, typeof mintSchema>>(true);
});
