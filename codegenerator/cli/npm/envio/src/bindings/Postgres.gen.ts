/* TypeScript file generated from Postgres.res by genType. */

/* eslint-disable */
/* tslint:disable */

import type postgres from 'postgres';

// Fix: TypeScript's Omit doesn't preserve call signatures, so TransactionSql
// loses the ability to be called as a tagged template or helper function.
// We augment the module to restore these signatures.
declare module 'postgres' {
  interface TransactionSql<TTypes extends Record<string, unknown> = {}> {
    <T, K extends readonly any[]>(first: T, ...rest: K): any;
    <T extends readonly (object | undefined)[] = postgres.Row[]>(
      template: TemplateStringsArray,
      ...parameters: readonly any[]
    ): postgres.PendingQuery<T>;
  }
}

export type sql = postgres.Sql;
