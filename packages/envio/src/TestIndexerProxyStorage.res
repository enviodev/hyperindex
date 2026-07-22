// Serializable representation of a batch's entity changes, shared between the
// indexer's writeBatch adapter and the in-memory store's handleWriteBatch.
// Entities are encoded as JSON so the store's typed comparisons (bigint /
// BigDecimal) round-trip through the field schemas the same way as the real
// storage layer.
@tag("type")
type serializableChange =
  | @as("SET") Set({entityId: string, entity: JSON.t, checkpointId: bigint})
  | @as("DELETE") Delete({entityId: string, checkpointId: bigint})

type serializableUpdatedEntity = {
  entityName: string,
  changes: array<serializableChange>,
}
