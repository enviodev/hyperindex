/**
 * Static description of the differential fixture (scenarios/test_codegen's
 * schema.graphql) in the exact shape Hasura.res derives when tracking:
 * which tables are exposed, and the manual object/array relationships.
 */

export interface ObjectRelationship {
  name: string;
  /** db column on this table mapping to the remote table's id */
  column: string;
  remoteTable: string;
  /** GraphQL docstring on the linking field, sent as the relationship's `comment` */
  description?: string;
}

export interface ArrayRelationship {
  name: string;
  /** db column on the remote table mapping to this table's id */
  remoteColumn: string;
  remoteTable: string;
  /** GraphQL docstring on the `@derivedFrom` field, sent as the relationship's `comment` */
  description?: string;
}

export interface EntityTable {
  name: string;
  /** GraphQL docstring on the entity type, sent as the table's `comment` */
  description?: string;
  /** GraphQL docstrings on scalar fields, keyed by db column name, sent as `column_config[].comment` */
  columnDescriptions?: Record<string, string>;
  objectRelationships?: ObjectRelationship[];
  arrayRelationships?: ArrayRelationship[];
}

export const entityTables: EntityTable[] = [
  {
    name: "A",
    objectRelationships: [{ name: "b", column: "b_id", remoteTable: "B" }],
  },
  {
    name: "B",
    objectRelationships: [{ name: "c", column: "c_id", remoteTable: "C" }],
    arrayRelationships: [{ name: "a", remoteColumn: "b_id", remoteTable: "A" }],
  },
  {
    name: "C",
    objectRelationships: [{ name: "a", column: "a_id", remoteTable: "A" }],
    arrayRelationships: [{ name: "d", remoteColumn: "c", remoteTable: "D" }],
  },
  { name: "CustomSelectionTestPass" },
  { name: "D" },
  { name: "EntityWith63LenghtName______________________________________one" },
  { name: "EntityWith63LenghtName______________________________________two" },
  { name: "EntityWithAllNonArrayTypes" },
  { name: "EntityWithAllTypes" },
  { name: "EntityWithBigDecimal" },
  { name: "EntityWithRestrictedReScriptField" },
  { name: "EntityWithTimestamp" },
  {
    name: "Gravatar",
    objectRelationships: [
      { name: "owner", column: "owner_id", remoteTable: "User" },
    ],
  },
  {
    name: "NftCollection",
    arrayRelationships: [
      { name: "tokens", remoteColumn: "collection_id", remoteTable: "Token" },
    ],
  },
  { name: "PostgresNumericPrecisionEntityTester" },
  { name: "SimpleEntity" },
  { name: "SimulateTestEvent" },
  {
    name: "Token",
    objectRelationships: [
      { name: "collection", column: "collection_id", remoteTable: "NftCollection" },
      { name: "owner", column: "owner_id", remoteTable: "User" },
    ],
  },
  {
    name: "User",
    description: "A user of the protocol, keyed by their wallet address.",
    columnDescriptions: {
      address: "The user's wallet address, lowercased.",
    },
    objectRelationships: [
      {
        name: "gravatar",
        column: "gravatar_id",
        remoteTable: "Gravatar",
        description: "The user's gravatar profile, if they have set one.",
      },
    ],
    arrayRelationships: [
      {
        name: "tokens",
        remoteColumn: "owner_id",
        remoteTable: "Token",
        description: "Tokens currently owned by this user.",
      },
    ],
  },
];

/** Internal tables tracked by Hasura.trackDatabase alongside user entities. */
export const internalTables = ["raw_events", "_meta", "chain_metadata"];

export const allTrackedTables = [
  ...internalTables,
  ...entityTables.map((t) => t.name),
];
