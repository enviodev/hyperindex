@unboxed
type ssl = Bool(bool) | Options({rejectUnauthorized: bool})

type config = {
  host?: string,
  port?: int,
  user?: string,
  password?: string,
  database?: string,
  ssl?: ssl,
  max?: int,
}

type queryConfig = {
  text: string,
  values: unknown,
  name?: string,
}

type pool

@module("pg") @new external makePool: config => pool = "Pool"
