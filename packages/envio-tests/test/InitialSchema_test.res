open Vitest

// What a fresh start leaves in the database, read back from the catalog: every
// table and view with its columns, the keys, the enum types, who may use the
// schema, and the chains' first rows. Hasura and anyone querying the database
// directly see exactly this, however the statements that made it are spelled.

let scenario = Scenario.make(
  ~configYaml=`
name: initial-schema
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 100
    end_block: 200
    max_reorg_depth: 10
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
  - id: 137
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    max_reorg_depth: 200
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`,
  ~schema=`
enum Kind {
  FIRST
  SECOND
}

type Owner {
  id: ID!
}

type Asset {
  id: ID!
  owner: Owner!
  name: String
  amount: BigInt!
  price: BigDecimal! @config(precision: 10, scale: 8)
  ratio: Float!
  count: Int!
  flag: Boolean!
  at: Timestamp
  data: Bytes!
  doc: Json!
  kind: Kind!
  tags: [String!]!
  amounts: [BigInt!]!
}
`,
  ~unsupported=[{backend: #clickhouse, reason: "reads the Postgres catalog"}],
)

type relation = {name: string, kind: string, columns: string}
type key = {table: string, columns: string}
type enumType = {name: string, labels: string}

describe("A fresh start", () => {
  scenario->Scenario.it(
    "creates the schema the indexer and Hasura read",
    ~sources=[{chain: 1}, {chain: 137}],
    async (~t, ~indexer, ~source as _) => {
      let {sql, pgSchema} = indexer.pg
      let params = [pgSchema->(Utils.magic: string => unknown)]
      let relations: array<relation> = await sql->Sql.queryForTests(
        `SELECT c.relname::text AS "name", c.relkind::text AS "kind",
  string_agg(
    a.attname || ' ' || format_type(a.atttypid, a.atttypmod)
      || CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END
      || COALESCE(' DEFAULT ' || pg_get_expr(d.adbin, d.adrelid), ''),
    ', ' ORDER BY a.attnum
  ) AS "columns"
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
WHERE n.nspname = $1 AND c.relkind IN ('r', 'v', 'p')
GROUP BY c.relname, c.relkind
ORDER BY c.relname COLLATE "C";`,
        ~params,
      )
      let keys: array<key> = await sql->Sql.queryForTests(
        `SELECT t.relname::text AS "table",
  string_agg(a.attname, ', ' ORDER BY k.ord) AS "columns"
FROM pg_constraint con
JOIN pg_class t ON t.oid = con.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
CROSS JOIN unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
WHERE n.nspname = $1 AND con.contype = 'p'
GROUP BY t.relname
ORDER BY t.relname COLLATE "C";`,
        ~params,
      )
      let enums: array<enumType> = await sql->Sql.queryForTests(
        `SELECT ty.typname::text AS "name",
  string_agg(e.enumlabel, ', ' ORDER BY e.enumsortorder) AS "labels"
FROM pg_type ty
JOIN pg_namespace n ON n.oid = ty.typnamespace
JOIN pg_enum e ON e.enumtypid = ty.oid
WHERE n.nspname = $1
GROUP BY ty.typname
ORDER BY ty.typname COLLATE "C";`,
        ~params,
      )
      let access: array<{
        "public": bool,
      }> = await sql->Sql.queryForTests(
        `SELECT has_schema_privilege('public', $1, 'USAGE')
  AND has_schema_privilege('public', $1, 'CREATE') AS "public";`,
        ~params,
      )
      let meta: array<JSON.t> = await sql->Sql.queryForTests(
        `SELECT row_to_json(m) AS "row" FROM "${pgSchema}"."_meta" m;`,
      )
      let chainMetadata: array<JSON.t> = await sql->Sql.queryForTests(
        `SELECT row_to_json(m) AS "row" FROM "${pgSchema}"."chain_metadata" m ORDER BY m.chain_id;`,
      )

      t.expect((
        // A type or sequence outside the search path prints qualified by the
        // test's own schema.
        relations->Array.map(
          r => `${r.kind} ${r.name}(${r.columns->String.replaceAll(`${pgSchema}.`, "")})`,
        ),
        keys->Array.map(k => `${k.table}(${k.columns})`),
        enums->Array.map(e => `${e.name}(${e.labels})`),
        access->Array.map(row => row["public"]),
        meta,
        chainMetadata,
      )).toEqual((
        [
          "r Asset(id text NOT NULL, owner_id text NOT NULL, name text, amount numeric NOT NULL, price numeric(10,8) NOT NULL, ratio double precision NOT NULL, count integer NOT NULL, flag boolean NOT NULL, at timestamp with time zone, data text NOT NULL, doc jsonb NOT NULL, kind kind NOT NULL, tags text[] NOT NULL, amounts numeric[] NOT NULL)",
          "r Owner(id text NOT NULL)",
          "v _meta(chainId integer, ecosystem text, startBlock integer, endBlock integer, progressBlock integer, progressBlockTime timestamp with time zone, bufferBlock integer, firstEventBlock integer, eventsProcessed real, sourceBlock integer, readyAt timestamp with time zone, isReady boolean)",
          "v chain_metadata(block_height integer, chain_id integer, ecosystem text, end_block integer, first_event_block_number integer, is_hyper_sync boolean, latest_fetched_block_number integer, latest_processed_block integer, num_batches_fetched integer, num_events_processed real, start_block integer, timestamp_caught_up_to_head_or_endblock timestamp with time zone)",
          "r envio_addresses(chain_id integer NOT NULL, address bytea NOT NULL, contract_id smallint NOT NULL, registration_block integer NOT NULL)",
          "r envio_chains(id integer NOT NULL, ecosystem text NOT NULL, start_block integer NOT NULL, end_block integer, max_reorg_depth integer NOT NULL, buffer_block integer NOT NULL, source_block integer NOT NULL, first_event_block integer, ready_at timestamp with time zone, events_processed bigint NOT NULL, _is_hyper_sync boolean NOT NULL, progress_block integer NOT NULL, progress_block_time timestamp with time zone, checkpoint_id bigint NOT NULL)",
          "r envio_checkpoints(chain_id integer NOT NULL, id bigint NOT NULL, block_number integer NOT NULL, block_hash text, events_processed integer NOT NULL)",
          "r envio_contracts(id smallint NOT NULL, name text NOT NULL)",
          "r envio_history_Asset(id text NOT NULL, owner_id text, name text, amount numeric, price numeric(10,8), ratio double precision, count integer, flag boolean, at timestamp with time zone, data text, doc jsonb, kind kind, tags text[], amounts numeric[], envio_checkpoint_id bigint NOT NULL, envio_change envio_history_change NOT NULL)",
          "r envio_history_Owner(id text NOT NULL, envio_checkpoint_id bigint NOT NULL, envio_change envio_history_change NOT NULL)",
          "r envio_info(id integer NOT NULL DEFAULT 1, config text NOT NULL, instance text NOT NULL)",
          "r raw_events(chain_id integer NOT NULL, event_id bigint NOT NULL, event_name text NOT NULL, contract_name text NOT NULL, block_number integer NOT NULL, log_index integer NOT NULL, src_address text NOT NULL, block_hash text NOT NULL, block_timestamp integer NOT NULL, block_fields jsonb NOT NULL, transaction_fields jsonb NOT NULL, params jsonb NOT NULL, serial bigint NOT NULL DEFAULT nextval('raw_events_serial_seq'::regclass))",
        ],
        [
          "Asset(id)",
          "Owner(id)",
          "envio_addresses(chain_id, address, contract_id)",
          "envio_chains(id)",
          "envio_checkpoints(id)",
          "envio_contracts(id)",
          "envio_history_Asset(id, envio_checkpoint_id)",
          "envio_history_Owner(id, envio_checkpoint_id)",
          "envio_info(id)",
          "raw_events(serial)",
        ],
        ["envio_history_change(SET, DELETE)", "kind(FIRST, SECOND)"],
        [true],
        %raw(`[
          {"row": {"chainId": 1, "ecosystem": "evm", "startBlock": 100, "endBlock": 200, "progressBlock": -1, "progressBlockTime": null, "bufferBlock": -1, "firstEventBlock": null, "eventsProcessed": 0, "sourceBlock": 0, "readyAt": null, "isReady": false}},
          {"row": {"chainId": 137, "ecosystem": "evm", "startBlock": 0, "endBlock": null, "progressBlock": -1, "progressBlockTime": null, "bufferBlock": -1, "firstEventBlock": null, "eventsProcessed": 0, "sourceBlock": 0, "readyAt": null, "isReady": false}}
        ]`),
        %raw(`[
          {"row": {"block_height": 0, "chain_id": 1, "ecosystem": "evm", "end_block": 200, "first_event_block_number": null, "is_hyper_sync": false, "latest_fetched_block_number": -1, "latest_processed_block": -1, "num_batches_fetched": 0, "num_events_processed": 0, "start_block": 100, "timestamp_caught_up_to_head_or_endblock": null}},
          {"row": {"block_height": 0, "chain_id": 137, "ecosystem": "evm", "end_block": null, "first_event_block_number": null, "is_hyper_sync": false, "latest_fetched_block_number": -1, "latest_processed_block": -1, "num_batches_fetched": 0, "num_events_processed": 0, "start_block": 0, "timestamp_caught_up_to_head_or_endblock": null}}
        ]`),
      ))
    },
  )
})
