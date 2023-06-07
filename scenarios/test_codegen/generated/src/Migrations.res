let sql = Postgres.makeSql(~config=Config.db->Obj.magic /* TODO: make this have the correct type */)

module RawEventsTable = {
  let createRawEventsTable: unit => promise<unit> = async () => {
    @warning("-21")
    let _ = await %raw("sql`
      DO $$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'event_type') THEN
          CREATE TYPE EVENT_TYPE AS ENUM (
          'GravatarContract_TestEventEvent',
                    'GravatarContract_NewGravatarEvent',
                    'GravatarContract_UpdatedGravatarEvent'
          ,
          'NftFactoryContract_SimpleNftCreatedEvent'
          ,
          'SimpleNftContract_TransferEvent'
          
          );
        END IF;
      END $$;
      `")

    @warning("-21")
    let _ = await %raw("sql`
      CREATE TABLE public.raw_events (
        chain_id INTEGER NOT NULL,
        event_id NUMERIC NOT NULL,
        block_number INTEGER NOT NULL,
        log_index INTEGER NOT NULL,
        transaction_index INTEGER NOT NULL,
        transaction_hash TEXT NOT NULL,
        src_address TEXT NOT NULL,
        block_hash TEXT NOT NULL,
        block_timestamp INTEGER NOT NULL,
        event_type EVENT_TYPE NOT NULL,
        params JSON NOT NULL,
        db_write_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (chain_id, event_id)
      );
      `")
  }

  @@warning("-21")
  let dropRawEventsTable = async () => {
    let _ = await %raw("sql`
      DROP TABLE IF EXISTS public.raw_events;
    `")
    let _ = await %raw("sql`
      DROP TYPE IF EXISTS EVENT_TYPE CASCADE;
    `")
  }
  @@warning("+21")
}

module DynamicContractRegistryTable = {
  let createDynamicContractRegistryTable: unit => promise<unit> = async () => {
    @warning("-21")
    let _ = await %raw("sql`
      DO $$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'contract_type') THEN
          CREATE TYPE CONTRACT_TYPE AS ENUM (
          'Gravatar',
          'NftFactory',
          'SimpleNft'
          );
        END IF;
      END $$;
      `")

    @warning("-21")
    let _ = await %raw("sql`
      CREATE TABLE public.dynamic_contract_registry (
        chain_id INTEGER NOT NULL,
        event_id NUMERIC NOT NULL,
        contract_address TEXT NOT NULL,
        contract_type CONTRACT_TYPE NOT NULL,
        PRIMARY KEY (chain_id, contract_address)
      );
      `")
  }

  @@warning("-21")
  let dropDynamicContractRegistryTable = async () => {
    let _ = await %raw("sql`
      DROP TABLE IF EXISTS public.dynamic_contract_registry;
    `")
    let _ = await %raw("sql`
      DROP TYPE IF EXISTS EVENT_TYPE CASCADE;
    `")
  }
  @@warning("+21")
}

module User = {
  let createUserTable: unit => promise<unit> = async () => {
    await %raw(
      "sql`CREATE TABLE \"public\".\"user\" (\"id\" text NOT NULL,\"address\" text NOT NULL,\"gravatar\" text,\"updatesCountOnUserForTesting\" integer NOT NULL,\"tokens\" text[] NOT NULL, event_chain_id INTEGER NOT NULL, event_id NUMERIC NOT NULL, db_write_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP, UNIQUE (\"id\"));`"
    )
  }

  let deleteUserTable: unit => promise<unit> = async () => {
    // NOTE: we can refine the `IF EXISTS` part because this now prints to the terminal if the table doesn't exist (which isn't nice for the developer).
    await %raw("sql`DROP TABLE IF EXISTS \"public\".\"user\";`")
  }
}

module Gravatar = {
  let createGravatarTable: unit => promise<unit> = async () => {
    await %raw(
      "sql`CREATE TABLE \"public\".\"gravatar\" (\"id\" text NOT NULL,\"owner\" text NOT NULL,\"displayName\" text NOT NULL,\"imageUrl\" text NOT NULL,\"updatesCount\" numeric NOT NULL, event_chain_id INTEGER NOT NULL, event_id NUMERIC NOT NULL, db_write_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP, UNIQUE (\"id\"));`"
    )
  }

  let deleteGravatarTable: unit => promise<unit> = async () => {
    // NOTE: we can refine the `IF EXISTS` part because this now prints to the terminal if the table doesn't exist (which isn't nice for the developer).
    await %raw("sql`DROP TABLE IF EXISTS \"public\".\"gravatar\";`")
  }
}

module Nftcollection = {
  let createNftcollectionTable: unit => promise<unit> = async () => {
    await %raw(
      "sql`CREATE TABLE \"public\".\"nftcollection\" (\"id\" text NOT NULL,\"contractAddress\" text NOT NULL,\"name\" text NOT NULL,\"symbol\" text NOT NULL,\"maxSupply\" numeric NOT NULL,\"currentSupply\" integer NOT NULL, event_chain_id INTEGER NOT NULL, event_id NUMERIC NOT NULL, db_write_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP, UNIQUE (\"id\"));`"
    )
  }

  let deleteNftcollectionTable: unit => promise<unit> = async () => {
    // NOTE: we can refine the `IF EXISTS` part because this now prints to the terminal if the table doesn't exist (which isn't nice for the developer).
    await %raw("sql`DROP TABLE IF EXISTS \"public\".\"nftcollection\";`")
  }
}

module Token = {
  let createTokenTable: unit => promise<unit> = async () => {
    await %raw(
      "sql`CREATE TABLE \"public\".\"token\" (\"id\" text NOT NULL,\"tokenId\" numeric NOT NULL,\"collection\" text NOT NULL,\"owner\" text NOT NULL, event_chain_id INTEGER NOT NULL, event_id NUMERIC NOT NULL, db_write_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP, UNIQUE (\"id\"));`"
    )
  }

  let deleteTokenTable: unit => promise<unit> = async () => {
    // NOTE: we can refine the `IF EXISTS` part because this now prints to the terminal if the table doesn't exist (which isn't nice for the developer).
    await %raw("sql`DROP TABLE IF EXISTS \"public\".\"token\";`")
  }
}

module A = {
  let createATable: unit => promise<unit> = async () => {
    await %raw(
      "sql`CREATE TABLE \"public\".\"a\" (\"id\" text NOT NULL,\"b\" text NOT NULL, event_chain_id INTEGER NOT NULL, event_id NUMERIC NOT NULL, db_write_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP, UNIQUE (\"id\"));`"
    )
  }

  let deleteATable: unit => promise<unit> = async () => {
    // NOTE: we can refine the `IF EXISTS` part because this now prints to the terminal if the table doesn't exist (which isn't nice for the developer).
    await %raw("sql`DROP TABLE IF EXISTS \"public\".\"a\";`")
  }
}

module B = {
  let createBTable: unit => promise<unit> = async () => {
    await %raw(
      "sql`CREATE TABLE \"public\".\"b\" (\"id\" text NOT NULL,\"a\" text[] NOT NULL,\"c\" text, event_chain_id INTEGER NOT NULL, event_id NUMERIC NOT NULL, db_write_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP, UNIQUE (\"id\"));`"
    )
  }

  let deleteBTable: unit => promise<unit> = async () => {
    // NOTE: we can refine the `IF EXISTS` part because this now prints to the terminal if the table doesn't exist (which isn't nice for the developer).
    await %raw("sql`DROP TABLE IF EXISTS \"public\".\"b\";`")
  }
}

module C = {
  let createCTable: unit => promise<unit> = async () => {
    await %raw(
      "sql`CREATE TABLE \"public\".\"c\" (\"id\" text NOT NULL,\"a\" text NOT NULL, event_chain_id INTEGER NOT NULL, event_id NUMERIC NOT NULL, db_write_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP, UNIQUE (\"id\"));`"
    )
  }

  let deleteCTable: unit => promise<unit> = async () => {
    // NOTE: we can refine the `IF EXISTS` part because this now prints to the terminal if the table doesn't exist (which isn't nice for the developer).
    await %raw("sql`DROP TABLE IF EXISTS \"public\".\"c\";`")
  }
}

let deleteAllTables: unit => promise<unit> = async () => {
  // NOTE: we can refine the `IF EXISTS` part because this now prints to the terminal if the table doesn't exist (which isn't nice for the developer).

  @warning("-21")
  await (
    %raw(
      "sql.unsafe`DROP SCHEMA public CASCADE;CREATE SCHEMA public;GRANT ALL ON SCHEMA public TO postgres;GRANT ALL ON SCHEMA public TO public;`"
    )
  )
}

type t
@module external process: t = "process"

@send external exit: (t, unit) => unit = "exit"

// TODO: all the migration steps should run as a single transaction
let runUpMigrations = async () => {
  await RawEventsTable.createRawEventsTable()
  await DynamicContractRegistryTable.createDynamicContractRegistryTable()
  // TODO: catch and handle query errors
  await User.createUserTable()
  await Gravatar.createGravatarTable()
  await Nftcollection.createNftcollectionTable()
  await Token.createTokenTable()
  await A.createATable()
  await B.createBTable()
  await C.createCTable()
}

let runDownMigrations = async () => {
  //
  // await User.deleteUserTable()
  //
  // await Gravatar.deleteGravatarTable()
  //
  // await Nftcollection.deleteNftcollectionTable()
  //
  // await Token.deleteTokenTable()
  //
  // await A.deleteATable()
  //
  // await B.deleteBTable()
  //
  // await C.deleteCTable()
  //

  await RawEventsTable.dropRawEventsTable()
  await DynamicContractRegistryTable.dropDynamicContractRegistryTable()

  // NOTE: For now delete any remaining tables.
  await deleteAllTables()
}

let setupDb = async () => {
  // TODO: we should make a hash of the schema file (that gets stored in the DB) and either drop the tables and create new ones or keep this migration.
  //       for now we always run the down migration.
  // if (process.env.MIGRATE === "force" || hash_of_schema_file !== hash_of_current_schema)
  await runDownMigrations()
  // else
  //   await clearDb()

  await runUpMigrations()

  process->exit()
}
