// This is to prevent tsc --noEmit from failing
// when importing code from .res.mjs files in genType .ts files
// After we upgrade GenType and it starts to include ts-ignore,
// the line can be removed.
export type sql = any;
export const unsafe: (sql: sql, text: string) => Promise<any[]>;
export const preparedUnsafe: (sql: sql, text: string, values: unknown) => Promise<any[]>;
