/*
 * Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features
 */
import { AllEvents } from "generated";

AllEvents.UnitLog.handler(async (_: any) => {});

// Add underscore here, because otherwise ReScript adds $$ which breaks runtime
AllEvents.Option_.handler(async (_: any) => {});

AllEvents.SimpleStructWithOptionalField.handler(async (_: any) => {});

AllEvents.U8Log.handler(async (_: any) => {});

AllEvents.ArrayLog.handler(async (_: any) => {});

AllEvents.Result.handler(async (_: any) => {});

AllEvents.U64Log.handler(async (_: any) => {});

AllEvents.B256Log.handler(async (_: any) => {});

AllEvents.U32Log.handler(async (_: any) => {});

AllEvents.Status.handler(async (_: any) => {});

AllEvents.U16Log.handler(async (_: any) => {});

AllEvents.TupleLog.handler(async (_: any) => {});

AllEvents.SimpleStruct.handler(async (_: any) => {});

AllEvents.UnknownLog.handler(async (_: any) => {});

AllEvents.BoolLog.handler(async (_: any) => {}, { wildcard: true });

AllEvents.StrLog.handler(async (_: any) => {});

AllEvents.Option2.handler(async (_: any) => {});
