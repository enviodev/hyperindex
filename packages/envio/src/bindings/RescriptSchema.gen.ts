// Shim: the new rescript builder emits relative gentype imports for
// cross-package types. Re-export from the actual rescript-schema package.
export type { S_t, S_error, S_errorCode, S_Path_t, Result, Json } from "rescript-schema/RescriptSchema.gen.js";
