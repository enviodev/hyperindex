// This is to prevent tsc --noEmit from failing
// when importing code from .res.mjs files in genType .ts files
// After we upgrade GenType and it starts to include ts-ignore,
// the line can be removed.
export type pool = any;
export const unsafe: (pool: pool, text: string) => Promise<any[]>;
export const preparedUnsafe: (pool: pool, name: string, text: string, values: unknown) => Promise<any[]>;
