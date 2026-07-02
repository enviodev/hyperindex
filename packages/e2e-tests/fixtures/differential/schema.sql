-- Differential-suite fixture schema.
-- Generated from scenarios/test_codegen by `envio local db-migrate setup` +
-- pg_dump. Regenerate with: pnpm gen:differential-fixture
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
GRANT ALL ON SCHEMA public TO public;
CREATE TYPE public.accounttype AS ENUM (
    'ADMIN',
    'USER'
);
CREATE TYPE public.envio_history_change AS ENUM (
    'SET',
    'DELETE'
);
CREATE TYPE public.gravatarsize AS ENUM (
    'SMALL',
    'MEDIUM',
    'LARGE'
);
CREATE FUNCTION public.get_cache_row_count(table_name text) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
  result integer;
BEGIN
  EXECUTE format('SELECT COUNT(*) FROM "public".%I', table_name) INTO result;
  RETURN result;
END;
$$;
CREATE TABLE public."A" (
    id text NOT NULL,
    b_id text NOT NULL,
    "optionalStringToTestLinkedEntities" text
);
CREATE TABLE public."B" (
    id text NOT NULL,
    c_id text
);
CREATE TABLE public."C" (
    id text NOT NULL,
    a_id text NOT NULL,
    "stringThatIsMirroredToA" text NOT NULL
);
CREATE TABLE public."CustomSelectionTestPass" (
    id text NOT NULL
);
CREATE TABLE public."D" (
    id text NOT NULL,
    c text NOT NULL
);
CREATE TABLE public."EntityWith63LenghtName______________________________________one" (
    id text NOT NULL
);
CREATE TABLE public."EntityWith63LenghtName______________________________________two" (
    id text NOT NULL
);
CREATE TABLE public."EntityWithAllNonArrayTypes" (
    id text NOT NULL,
    string text NOT NULL,
    "optString" text,
    int_ integer NOT NULL,
    "optInt" integer,
    float_ double precision NOT NULL,
    "optFloat" double precision,
    bool boolean NOT NULL,
    "optBool" boolean,
    "bigInt" numeric NOT NULL,
    "optBigInt" numeric,
    "bigDecimal" numeric NOT NULL,
    "optBigDecimal" numeric,
    "bigDecimalWithConfig" numeric(10,8) NOT NULL,
    "enumField" public.accounttype NOT NULL,
    "optEnumField" public.accounttype,
    "timestamp" timestamp with time zone NOT NULL,
    "optTimestamp" timestamp with time zone
);
CREATE TABLE public."EntityWithAllTypes" (
    id text NOT NULL,
    string text NOT NULL,
    "optString" text,
    "arrayOfStrings" text[] NOT NULL,
    int_ integer NOT NULL,
    "optInt" integer,
    "arrayOfInts" integer[] NOT NULL,
    float_ double precision NOT NULL,
    "optFloat" double precision,
    "arrayOfFloats" double precision[] NOT NULL,
    bool boolean NOT NULL,
    "optBool" boolean,
    "bigInt" numeric NOT NULL,
    "optBigInt" numeric,
    "arrayOfBigInts" text[] NOT NULL,
    "bigDecimal" numeric NOT NULL,
    "optBigDecimal" numeric,
    "bigDecimalWithConfig" numeric(10,8) NOT NULL,
    "arrayOfBigDecimals" text[] NOT NULL,
    "timestamp" timestamp with time zone NOT NULL,
    "optTimestamp" timestamp with time zone,
    json jsonb NOT NULL,
    "enumField" public.accounttype NOT NULL,
    "optEnumField" public.accounttype
);
CREATE TABLE public."EntityWithBigDecimal" (
    id text NOT NULL,
    "bigDecimal" numeric NOT NULL
);
CREATE TABLE public."EntityWithRestrictedReScriptField" (
    id text NOT NULL,
    type text NOT NULL
);
CREATE TABLE public."EntityWithTimestamp" (
    id text NOT NULL,
    "timestamp" timestamp with time zone NOT NULL
);
CREATE TABLE public."Gravatar" (
    id text NOT NULL,
    owner_id text NOT NULL,
    "displayName" text NOT NULL,
    "imageUrl" text NOT NULL,
    "updatesCount" numeric NOT NULL,
    size public.gravatarsize NOT NULL
);
CREATE TABLE public."NftCollection" (
    id text NOT NULL,
    "contractAddress" text NOT NULL,
    name text NOT NULL,
    symbol text NOT NULL,
    "maxSupply" numeric NOT NULL,
    "currentSupply" integer NOT NULL
);
CREATE TABLE public."PostgresNumericPrecisionEntityTester" (
    id text NOT NULL,
    "exampleBigInt" numeric(76,0),
    "exampleBigIntRequired" numeric(77,0) NOT NULL,
    "exampleBigIntArray" numeric(78,0)[],
    "exampleBigIntArrayRequired" numeric(79,0)[] NOT NULL,
    "exampleBigDecimal" numeric(80,5),
    "exampleBigDecimalRequired" numeric(81,5) NOT NULL,
    "exampleBigDecimalArray" numeric(82,5)[],
    "exampleBigDecimalArrayRequired" numeric(83,5)[] NOT NULL,
    "exampleBigDecimalOtherOrder" numeric(84,6) NOT NULL
);
CREATE TABLE public."SimpleEntity" (
    id text NOT NULL,
    value text NOT NULL
);
CREATE TABLE public."SimulateTestEvent" (
    id text NOT NULL,
    "blockNumber" integer NOT NULL,
    "logIndex" integer NOT NULL,
    "timestamp" integer NOT NULL
);
CREATE TABLE public."Token" (
    id text NOT NULL,
    "tokenId" numeric NOT NULL,
    collection_id text NOT NULL,
    owner_id text NOT NULL
);
CREATE TABLE public."User" (
    id text NOT NULL,
    address text NOT NULL,
    gravatar_id text,
    "updatesCountOnUserForTesting" integer NOT NULL,
    "accountType" public.accounttype NOT NULL
);
CREATE TABLE public.envio_chains (
    id integer NOT NULL,
    start_block integer NOT NULL,
    end_block integer,
    max_reorg_depth integer NOT NULL,
    buffer_block integer NOT NULL,
    source_block integer NOT NULL,
    first_event_block integer,
    ready_at timestamp with time zone,
    events_processed bigint NOT NULL,
    _is_hyper_sync boolean NOT NULL,
    progress_block integer NOT NULL
);
CREATE VIEW public._meta AS
 SELECT id AS "chainId",
    start_block AS "startBlock",
    end_block AS "endBlock",
    progress_block AS "progressBlock",
    buffer_block AS "bufferBlock",
    first_event_block AS "firstEventBlock",
    (events_processed)::real AS "eventsProcessed",
    source_block AS "sourceBlock",
    ready_at AS "readyAt",
    (ready_at IS NOT NULL) AS "isReady"
   FROM public.envio_chains
  ORDER BY id;
CREATE VIEW public.chain_metadata AS
 SELECT source_block AS block_height,
    id AS chain_id,
    end_block,
    first_event_block AS first_event_block_number,
    _is_hyper_sync AS is_hyper_sync,
    buffer_block AS latest_fetched_block_number,
    progress_block AS latest_processed_block,
    0 AS num_batches_fetched,
    (events_processed)::real AS num_events_processed,
    start_block,
    ready_at AS timestamp_caught_up_to_head_or_endblock
   FROM public.envio_chains;
CREATE TABLE public.envio_addresses (
    id text NOT NULL,
    chain_id integer NOT NULL,
    registration_block integer NOT NULL,
    registration_log_index integer NOT NULL,
    contract_name text NOT NULL
);
CREATE TABLE public.envio_checkpoints (
    id bigint NOT NULL,
    chain_id integer NOT NULL,
    block_number integer NOT NULL,
    block_hash text,
    events_processed integer NOT NULL
);
CREATE TABLE public."envio_history_A" (
    id text NOT NULL,
    b_id text,
    "optionalStringToTestLinkedEntities" text,
    envio_checkpoint_id bigint NOT NULL,
    envio_change public.envio_history_change NOT NULL
);
CREATE TABLE public."envio_history_B" (
    id text NOT NULL,
    c_id text,
    envio_checkpoint_id bigint NOT NULL,
    envio_change public.envio_history_change NOT NULL
);
CREATE TABLE public."envio_history_C" (
    id text NOT NULL,
    a_id text,
    "stringThatIsMirroredToA" text,
    envio_checkpoint_id bigint NOT NULL,
    envio_change public.envio_history_change NOT NULL
);
CREATE TABLE public."envio_history_CustomSelectionTestPass" (
    id text NOT NULL,
    envio_checkpoint_id bigint NOT NULL,
    envio_change public.envio_history_change NOT NULL
);
CREATE TABLE public."envio_history_D" (
    id text NOT NULL,
    c text,
    envio_checkpoint_id bigint NOT NULL,
    envio_change public.envio_history_change NOT NULL
);
CREATE TABLE public."envio_history_EntityWith63LenghtName__________________________5" (
    id text NOT NULL,
    envio_checkpoint_id bigint NOT NULL,
    envio_change public.envio_history_change NOT NULL
);
CREATE TABLE public."envio_history_EntityWith63LenghtName__________________________6" (
    id text NOT NULL,
    envio_checkpoint_id bigint NOT NULL,
    envio_change public.envio_history_change NOT NULL
);
CREATE TABLE public."envio_history_EntityWithAllNonArrayTypes" (
    id text NOT NULL,
    string text,
    "optString" text,
    int_ integer,
    "optInt" integer,
    float_ double precision,
    "optFloat" double precision,
    bool boolean,
    "optBool" boolean,
    "bigInt" numeric,
    "optBigInt" numeric,
    "bigDecimal" numeric,
    "optBigDecimal" numeric,
    "bigDecimalWithConfig" numeric(10,8),
    "enumField" public.accounttype,
    "optEnumField" public.accounttype,
    "timestamp" timestamp with time zone,
    "optTimestamp" timestamp with time zone,
    envio_checkpoint_id bigint NOT NULL,
    envio_change public.envio_history_change NOT NULL
);
CREATE TABLE public."envio_history_EntityWithAllTypes" (
    id text NOT NULL,
    string text,
    "optString" text,
    "arrayOfStrings" text[],
    int_ integer,
    "optInt" integer,
    "arrayOfInts" integer[],
    float_ double precision,
    "optFloat" double precision,
    "arrayOfFloats" double precision[],
    bool boolean,
    "optBool" boolean,
    "bigInt" numeric,
    "optBigInt" numeric,
    "arrayOfBigInts" text[],
    "bigDecimal" numeric,
    "optBigDecimal" numeric,
    "bigDecimalWithConfig" numeric(10,8),
    "arrayOfBigDecimals" text[],
    "timestamp" timestamp with time zone,
    "optTimestamp" timestamp with time zone,
    json jsonb,
    "enumField" public.accounttype,
    "optEnumField" public.accounttype,
    envio_checkpoint_id bigint NOT NULL,
    envio_change public.envio_history_change NOT NULL
);
CREATE TABLE public."envio_history_EntityWithBigDecimal" (
    id text NOT NULL,
    "bigDecimal" numeric,
    envio_checkpoint_id bigint NOT NULL,
    envio_change public.envio_history_change NOT NULL
);
CREATE TABLE public."envio_history_EntityWithRestrictedReScriptField" (
    id text NOT NULL,
    type text,
    envio_checkpoint_id bigint NOT NULL,
    envio_change public.envio_history_change NOT NULL
);
CREATE TABLE public."envio_history_EntityWithTimestamp" (
    id text NOT NULL,
    "timestamp" timestamp with time zone,
    envio_checkpoint_id bigint NOT NULL,
    envio_change public.envio_history_change NOT NULL
);
CREATE TABLE public."envio_history_Gravatar" (
    id text NOT NULL,
    owner_id text,
    "displayName" text,
    "imageUrl" text,
    "updatesCount" numeric,
    size public.gravatarsize,
    envio_checkpoint_id bigint NOT NULL,
    envio_change public.envio_history_change NOT NULL
);
CREATE TABLE public."envio_history_NftCollection" (
    id text NOT NULL,
    "contractAddress" text,
    name text,
    symbol text,
    "maxSupply" numeric,
    "currentSupply" integer,
    envio_checkpoint_id bigint NOT NULL,
    envio_change public.envio_history_change NOT NULL
);
CREATE TABLE public."envio_history_PostgresNumericPrecisionEntityTester" (
    id text NOT NULL,
    "exampleBigInt" numeric(76,0),
    "exampleBigIntRequired" numeric(77,0),
    "exampleBigIntArray" numeric(78,0)[],
    "exampleBigIntArrayRequired" numeric(79,0)[],
    "exampleBigDecimal" numeric(80,5),
    "exampleBigDecimalRequired" numeric(81,5),
    "exampleBigDecimalArray" numeric(82,5)[],
    "exampleBigDecimalArrayRequired" numeric(83,5)[],
    "exampleBigDecimalOtherOrder" numeric(84,6),
    envio_checkpoint_id bigint NOT NULL,
    envio_change public.envio_history_change NOT NULL
);
CREATE TABLE public."envio_history_SimpleEntity" (
    id text NOT NULL,
    value text,
    envio_checkpoint_id bigint NOT NULL,
    envio_change public.envio_history_change NOT NULL
);
CREATE TABLE public."envio_history_SimulateTestEvent" (
    id text NOT NULL,
    "blockNumber" integer,
    "logIndex" integer,
    "timestamp" integer,
    envio_checkpoint_id bigint NOT NULL,
    envio_change public.envio_history_change NOT NULL
);
CREATE TABLE public."envio_history_Token" (
    id text NOT NULL,
    "tokenId" numeric,
    collection_id text,
    owner_id text,
    envio_checkpoint_id bigint NOT NULL,
    envio_change public.envio_history_change NOT NULL
);
CREATE TABLE public."envio_history_User" (
    id text NOT NULL,
    address text,
    gravatar_id text,
    "updatesCountOnUserForTesting" integer,
    "accountType" public.accounttype,
    envio_checkpoint_id bigint NOT NULL,
    envio_change public.envio_history_change NOT NULL
);
CREATE TABLE public.envio_history_envio_addresses (
    id text NOT NULL,
    chain_id integer,
    registration_block integer,
    registration_log_index integer,
    contract_name text,
    envio_checkpoint_id bigint NOT NULL,
    envio_change public.envio_history_change NOT NULL
);
CREATE TABLE public.envio_info (
    id integer DEFAULT 1 NOT NULL,
    config text NOT NULL
);
CREATE TABLE public.raw_events (
    chain_id integer NOT NULL,
    event_id bigint NOT NULL,
    event_name text NOT NULL,
    contract_name text NOT NULL,
    block_number integer NOT NULL,
    log_index integer NOT NULL,
    src_address text NOT NULL,
    block_hash text NOT NULL,
    block_timestamp integer NOT NULL,
    block_fields jsonb NOT NULL,
    transaction_fields jsonb NOT NULL,
    params jsonb NOT NULL,
    serial bigint NOT NULL
);
CREATE SEQUENCE public.raw_events_serial_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.raw_events_serial_seq OWNED BY public.raw_events.serial;
ALTER TABLE ONLY public.raw_events ALTER COLUMN serial SET DEFAULT nextval('public.raw_events_serial_seq'::regclass);
ALTER TABLE ONLY public."A"
    ADD CONSTRAINT "A_pkey" PRIMARY KEY (id);
ALTER TABLE ONLY public."B"
    ADD CONSTRAINT "B_pkey" PRIMARY KEY (id);
ALTER TABLE ONLY public."C"
    ADD CONSTRAINT "C_pkey" PRIMARY KEY (id);
ALTER TABLE ONLY public."CustomSelectionTestPass"
    ADD CONSTRAINT "CustomSelectionTestPass_pkey" PRIMARY KEY (id);
ALTER TABLE ONLY public."D"
    ADD CONSTRAINT "D_pkey" PRIMARY KEY (id);
ALTER TABLE ONLY public."EntityWith63LenghtName______________________________________one"
    ADD CONSTRAINT "EntityWith63LenghtName_____________________________________pkey" PRIMARY KEY (id);
ALTER TABLE ONLY public."EntityWith63LenghtName______________________________________two"
    ADD CONSTRAINT "EntityWith63LenghtName____________________________________pkey1" PRIMARY KEY (id);
ALTER TABLE ONLY public."EntityWithAllNonArrayTypes"
    ADD CONSTRAINT "EntityWithAllNonArrayTypes_pkey" PRIMARY KEY (id);
ALTER TABLE ONLY public."EntityWithAllTypes"
    ADD CONSTRAINT "EntityWithAllTypes_pkey" PRIMARY KEY (id);
ALTER TABLE ONLY public."EntityWithBigDecimal"
    ADD CONSTRAINT "EntityWithBigDecimal_pkey" PRIMARY KEY (id);
ALTER TABLE ONLY public."EntityWithRestrictedReScriptField"
    ADD CONSTRAINT "EntityWithRestrictedReScriptField_pkey" PRIMARY KEY (id);
ALTER TABLE ONLY public."EntityWithTimestamp"
    ADD CONSTRAINT "EntityWithTimestamp_pkey" PRIMARY KEY (id);
ALTER TABLE ONLY public."Gravatar"
    ADD CONSTRAINT "Gravatar_pkey" PRIMARY KEY (id);
ALTER TABLE ONLY public."NftCollection"
    ADD CONSTRAINT "NftCollection_pkey" PRIMARY KEY (id);
ALTER TABLE ONLY public."PostgresNumericPrecisionEntityTester"
    ADD CONSTRAINT "PostgresNumericPrecisionEntityTester_pkey" PRIMARY KEY (id);
ALTER TABLE ONLY public."SimpleEntity"
    ADD CONSTRAINT "SimpleEntity_pkey" PRIMARY KEY (id);
ALTER TABLE ONLY public."SimulateTestEvent"
    ADD CONSTRAINT "SimulateTestEvent_pkey" PRIMARY KEY (id);
ALTER TABLE ONLY public."Token"
    ADD CONSTRAINT "Token_pkey" PRIMARY KEY (id);
ALTER TABLE ONLY public."User"
    ADD CONSTRAINT "User_pkey" PRIMARY KEY (id);
ALTER TABLE ONLY public.envio_addresses
    ADD CONSTRAINT envio_addresses_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.envio_chains
    ADD CONSTRAINT envio_chains_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.envio_checkpoints
    ADD CONSTRAINT envio_checkpoints_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public."envio_history_A"
    ADD CONSTRAINT "envio_history_A_pkey" PRIMARY KEY (id, envio_checkpoint_id);
ALTER TABLE ONLY public."envio_history_B"
    ADD CONSTRAINT "envio_history_B_pkey" PRIMARY KEY (id, envio_checkpoint_id);
ALTER TABLE ONLY public."envio_history_C"
    ADD CONSTRAINT "envio_history_C_pkey" PRIMARY KEY (id, envio_checkpoint_id);
ALTER TABLE ONLY public."envio_history_CustomSelectionTestPass"
    ADD CONSTRAINT "envio_history_CustomSelectionTestPass_pkey" PRIMARY KEY (id, envio_checkpoint_id);
ALTER TABLE ONLY public."envio_history_D"
    ADD CONSTRAINT "envio_history_D_pkey" PRIMARY KEY (id, envio_checkpoint_id);
ALTER TABLE ONLY public."envio_history_EntityWith63LenghtName__________________________5"
    ADD CONSTRAINT "envio_history_EntityWith63LenghtName_______________________pkey" PRIMARY KEY (id, envio_checkpoint_id);
ALTER TABLE ONLY public."envio_history_EntityWith63LenghtName__________________________6"
    ADD CONSTRAINT "envio_history_EntityWith63LenghtName______________________pkey1" PRIMARY KEY (id, envio_checkpoint_id);
ALTER TABLE ONLY public."envio_history_EntityWithAllNonArrayTypes"
    ADD CONSTRAINT "envio_history_EntityWithAllNonArrayTypes_pkey" PRIMARY KEY (id, envio_checkpoint_id);
ALTER TABLE ONLY public."envio_history_EntityWithAllTypes"
    ADD CONSTRAINT "envio_history_EntityWithAllTypes_pkey" PRIMARY KEY (id, envio_checkpoint_id);
ALTER TABLE ONLY public."envio_history_EntityWithBigDecimal"
    ADD CONSTRAINT "envio_history_EntityWithBigDecimal_pkey" PRIMARY KEY (id, envio_checkpoint_id);
ALTER TABLE ONLY public."envio_history_EntityWithRestrictedReScriptField"
    ADD CONSTRAINT "envio_history_EntityWithRestrictedReScriptField_pkey" PRIMARY KEY (id, envio_checkpoint_id);
ALTER TABLE ONLY public."envio_history_EntityWithTimestamp"
    ADD CONSTRAINT "envio_history_EntityWithTimestamp_pkey" PRIMARY KEY (id, envio_checkpoint_id);
ALTER TABLE ONLY public."envio_history_Gravatar"
    ADD CONSTRAINT "envio_history_Gravatar_pkey" PRIMARY KEY (id, envio_checkpoint_id);
ALTER TABLE ONLY public."envio_history_NftCollection"
    ADD CONSTRAINT "envio_history_NftCollection_pkey" PRIMARY KEY (id, envio_checkpoint_id);
ALTER TABLE ONLY public."envio_history_PostgresNumericPrecisionEntityTester"
    ADD CONSTRAINT "envio_history_PostgresNumericPrecisionEntityTester_pkey" PRIMARY KEY (id, envio_checkpoint_id);
ALTER TABLE ONLY public."envio_history_SimpleEntity"
    ADD CONSTRAINT "envio_history_SimpleEntity_pkey" PRIMARY KEY (id, envio_checkpoint_id);
ALTER TABLE ONLY public."envio_history_SimulateTestEvent"
    ADD CONSTRAINT "envio_history_SimulateTestEvent_pkey" PRIMARY KEY (id, envio_checkpoint_id);
ALTER TABLE ONLY public."envio_history_Token"
    ADD CONSTRAINT "envio_history_Token_pkey" PRIMARY KEY (id, envio_checkpoint_id);
ALTER TABLE ONLY public."envio_history_User"
    ADD CONSTRAINT "envio_history_User_pkey" PRIMARY KEY (id, envio_checkpoint_id);
ALTER TABLE ONLY public.envio_history_envio_addresses
    ADD CONSTRAINT envio_history_envio_addresses_pkey PRIMARY KEY (id, envio_checkpoint_id);
ALTER TABLE ONLY public.envio_info
    ADD CONSTRAINT envio_info_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.raw_events
    ADD CONSTRAINT raw_events_pkey PRIMARY KEY (serial);
CREATE INDEX "A_b_id" ON public."A" USING btree (b_id);
CREATE INDEX "D_c" ON public."D" USING btree (c);
CREATE INDEX "Token_collection_id" ON public."Token" USING btree (collection_id);
CREATE INDEX "Token_id_tokenId" ON public."Token" USING btree (id, "tokenId");
CREATE INDEX "Token_owner_id" ON public."Token" USING btree (owner_id);
CREATE INDEX "Token_tokenId" ON public."Token" USING btree ("tokenId");
CREATE INDEX "Token_tokenId_collection_id" ON public."Token" USING btree ("tokenId", collection_id);
CREATE INDEX "Token_tokenId_desc_owner_id" ON public."Token" USING btree ("tokenId" DESC, owner_id);
