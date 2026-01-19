// This is to prevent tsc --noEmit from failing
// when importing code from .res.mjs files in genType .ts files
// After we upgrade GenType and it starts to include ts-ignore,
// the line can be removed.
export const schema: any;
