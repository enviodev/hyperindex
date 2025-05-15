export type Json_t =
  | string
  | boolean
  | number
  | null
  | { [key: string]: Json_t }
  | Json_t[];

export type t = unknown;

export type Exn_t = Error;
