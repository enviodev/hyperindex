// Shim: the new rescript builder emits relative gentype imports for
// cross-package types. Re-export from the actual envio package.
export type { t } from "envio/src/Address.gen.js";
