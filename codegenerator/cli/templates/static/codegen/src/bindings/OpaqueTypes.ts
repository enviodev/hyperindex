export type EthersAddress = `0x${string}`;
export type Address = `0x${string}`;
export type Nullable<T> = null | T;
export type SingleOrMultiple<T> = T | T[];
export type HandlerWithOptions<Fn, Opts> = (fn: Fn, opt?: Opts) => void;
