module Schema = {
  type table<'rowType> = 'rowType

  @module("drizzle-orm/pg-core")
  external pgTable: (~name: string, ~fields: 'fields) => table<'rowType> = "pgTable"

  type field

  @module("drizzle-orm/pg-core")
  external serial: string => field = "serial"
  @module("drizzle-orm/pg-core")
  external text: string => field = "text"
  @module("drizzle-orm/pg-core")
  external integer: string => field = "integer"
  @module("drizzle-orm/pg-core")
  external numeric: string => field = "numeric"
  @module("drizzle-orm/pg-core")
  external boolean: string => field = "boolean"
  @module("drizzle-orm/pg-core")
  external json: string => field = "json"
  @module("drizzle-orm/pg-core")
  external jsonb: string => field = "jsonb"
  @module("drizzle-orm/pg-core")
  external time: string => field = "time"
  @module("drizzle-orm/pg-core")
  external timestamp: string => field = "timestamp"
  @module("drizzle-orm/pg-core")
  external date: string => field = "date"
  @module("drizzle-orm/pg-core")
  external varchar: string => field = "varchar"

  @send
  external primaryKey: field => field = "primaryKey"
}

module Pool = {
  type t

  type poolConfig = {
    host: string,
    port: int,
    user: string,
    password: string,
    database: string,
  }

  @module("pg") @new
  external make: (~config: poolConfig) => t = "Pool"
}

module Drizzle = {
  type db

  //TODO: If we use any other methods on drizzle perhap have a drizzle
  //type with send methods
  @module("drizzle-orm/node-postgres")
  external make: (~pool: Pool.t) => db = "drizzle"

  type selector

  @send
  external select: db => selector = "select"

  type insertion

  @send
  external insert: (db, ~table: Schema.table<'a>) => insertion = "insert"

  type migrationsConfig = {migrationsFolder: string}
  @module("drizzle-orm/node-postgres/migrator")
  external migrate: (db, migrationsConfig) => promise<unit> = "migrate"

  type returnedValues<'a> = 'a
  type values<'a, 'b> = (insertion, array<'a>) => returnedValues<'b>
  @send
  external values: (insertion, array<'a>) => returnedValues<'b> = "values"

  type targetConflict<'conflictId, 'valuesToSet> = {
    target: 'conflictId,
    set?: 'valuesToSet,
  }

  @send
  external onConflictDoUpdate: (returnedValues<'a>, targetConflict<'a, 'b>) => 'c =
    "onConflictDoUpdate"

  @send
  external onConflictDoNothing: (returnedValues<'a>, targetConflict<'a, 'b>) => 'c =
    "onConflictDoNothing"
}
