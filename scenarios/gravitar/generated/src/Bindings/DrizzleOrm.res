module Schema = {
  type table

  @module("drizzle-orm/pg-core")
  external pgTable: (~name: string, ~columns: 'columns) => table = "pgTable"

  type column

  @module("drizzle-orm/pg-core")
  external serial: string => column = "serial"
  @module("drizzle-orm/pg-core")
  external text: string => column = "text"
  @module("drizzle-orm/pg-core")
  external integer: string => column = "integer"
  @module("drizzle-orm/pg-core")
  external numeric: string => column = "numeric"
  @module("drizzle-orm/pg-core")
  external boolean: string => column = "boolean"
  @module("drizzle-orm/pg-core")
  external json: string => column = "json"
  @module("drizzle-orm/pg-core")
  external jsonb: string => column = "jsonb"
  @module("drizzle-orm/pg-core")
  external time: string => column = "time"
  @module("drizzle-orm/pg-core")
  external timestamp: string => column = "timestamp"
  @module("drizzle-orm/pg-core")
  external date: string => column = "date"
  @module("drizzle-orm/pg-core")
  external varchar: string => column = "varchar"

  @send
  external primaryKey: column => column = "primaryKey"
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

  @module
  external make: (~pool: Pool.t) => db = "drizzle-orm/node-postgres"

  type selector

  @send
  external select: db => selector = "select"

  type insertion

  @send
  external insert: (db, ~table: Schema.table) => insertion = "instert"

  type migrationsConfig = {migrationsFolder: string}
  @module("drizzle-orm/node-postgres/migrator")
  external migrate: (db, migrationsConfig) => promise<unit> = "migrate"
}
