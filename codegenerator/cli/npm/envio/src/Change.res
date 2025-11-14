@tag("type")
type t<'entity> =
  | @as("SET") Set({entityId: string, entity: 'entity, checkpointId: int})
  | @as("DELETE") Delete({entityId: string, checkpointId: int})

@get
external getEntityId: t<'entity> => string = "entityId"
@get
external getCheckpointId: t<'entity> => int = "checkpointId"
