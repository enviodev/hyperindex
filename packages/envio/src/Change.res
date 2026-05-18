@tag("type")
type t<'entity> =
  | @as("SET") Set({entityId: string, entity: 'entity, checkpointId: bigint})
  | @as("DELETE") Delete({entityId: string, checkpointId: bigint})

@get
external getEntityId: t<'entity> => string = "entityId"
@get
external getCheckpointId: t<'entity> => bigint = "checkpointId"
