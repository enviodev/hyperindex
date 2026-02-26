/* TypeScript file generated from PgStorage.res by genType. */

/* eslint-disable */
/* tslint:disable */

import * as PgStorageJS from './PgStorage.res.mjs';

import type {sql as Postgres_sql} from '../src/bindings/Postgres.gen.js';

export const makeClient: () => Postgres_sql = PgStorageJS.makeClient as any;
