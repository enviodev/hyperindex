/* TypeScript file generated from Pino.res by genType. */

/* eslint-disable */
/* tslint:disable */

export type logLevelUser = "udebug" | "uinfo" | "uwarn" | "uerror";

export abstract class pinoMessageBlob { protected opaque!: any }; /* simulate opaque types */

export type t = {
  readonly trace: (_1:pinoMessageBlob) => void; 
  readonly debug: (_1:pinoMessageBlob) => void; 
  readonly info: (_1:pinoMessageBlob) => void; 
  readonly warn: (_1:pinoMessageBlob) => void; 
  readonly error: (_1:pinoMessageBlob) => void; 
  readonly fatal: (_1:pinoMessageBlob) => void
};
