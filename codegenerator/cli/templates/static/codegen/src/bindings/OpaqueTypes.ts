export type EthersAddress = string;
export type Address = string;
export type Nullable<T> = null | T;
export type SingleOrMultiple<T> = T | T[];
export type HandlerWithOptions<Fn, Opts> = (fn: Fn, opt?: Opts) => void;
