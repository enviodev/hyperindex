@tag("type")
type t<'entity> =
  | @as("SET") Set({entityId: EntityId.t, entity: 'entity, checkpointId: bigint})
  | @as("DELETE") Delete({entityId: EntityId.t, checkpointId: bigint})

@get
external getEntityId: t<'entity> => EntityId.t = "entityId"
@get
external getCheckpointId: t<'entity> => bigint = "checkpointId"
