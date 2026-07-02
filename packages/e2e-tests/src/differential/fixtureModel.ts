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
}

export interface ArrayRelationship {
  name: string;
  /** db column on the remote table mapping to this table's id */
  remoteColumn: string;
  remoteTable: string;
}

export interface EntityTable {
  name: string;
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
    objectRelationships: [
      { name: "gravatar", column: "gravatar_id", remoteTable: "Gravatar" },
    ],
    arrayRelationships: [
      { name: "tokens", remoteColumn: "owner_id", remoteTable: "Token" },
    ],
  },
];

/** Internal tables tracked by Hasura.trackDatabase alongside user entities. */
export const internalTables = ["raw_events", "_meta", "chain_metadata"];

export const allTrackedTables = [
  ...internalTables,
  ...entityTables.map((t) => t.name),
];
