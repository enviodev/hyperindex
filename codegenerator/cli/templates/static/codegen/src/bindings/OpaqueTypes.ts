export type SingleOrMultiple<T> = T | T[];
export type HandlerWithOptions<Fn, Opts> = (fn: Fn, opt?: Opts) => void;
