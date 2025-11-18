@tag("type")
type t<'entity> =
  | @as("SET") Set({entityId: string, entity: 'entity, checkpointId: float})
  | @as("DELETE") Delete({entityId: string, checkpointId: float})

@get
external getEntityId: t<'entity> => string = "entityId"
@get
external getCheckpointId: t<'entity> => int = "checkpointId"
