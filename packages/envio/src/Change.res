@tag("type")
type t<'entity> =
  | @as("SET") Set({entityId: string, entity: 'entity, checkpointId: bigint, isRollbackDiff?: bool})
  | @as("DELETE") Delete({entityId: string, checkpointId: bigint, isRollbackDiff?: bool})

@get
external getEntityId: t<'entity> => string = "entityId"
@get
external getCheckpointId: t<'entity> => bigint = "checkpointId"
@get
external getIsRollbackDiffOpt: t<'entity> => option<bool> = "isRollbackDiff"

let isRollbackDiff = (change: t<'entity>): bool =>
  change->getIsRollbackDiffOpt->Belt.Option.getWithDefault(false)
