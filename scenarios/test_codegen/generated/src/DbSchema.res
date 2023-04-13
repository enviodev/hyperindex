open DrizzleOrm.Schema

module Gravatar = {
  type gravatarTablefields = {
    idExample: field, // todo
    id: field,
    owner: field,
    displayName: field,
    imageUrl: field,
    updatesCount: field,
  }

  %%private(
    let gravatarTablefields = {
      idExample: text("idExample")->primaryKey, // todo
      id: text("id"), // todo param.drizzleType eg. text integer etc // todo snake case
      owner: text("owner"), // todo param.drizzleType eg. text integer etc // todo snake case
      displayName: text("displayName"), // todo param.drizzleType eg. text integer etc // todo snake case
      imageUrl: text("imageUrl"), // todo param.drizzleType eg. text integer etc // todo snake case
      updatesCount: text("updatesCount"), // todo param.drizzleType eg. text integer etc // todo snake case
    }
  )

  type gravatarTableRow = {
    exampleId: DrizzleOrm.Schema.fieldSelector, //todo
    id: DrizzleOrm.Schema.fieldSelector,
    owner: DrizzleOrm.Schema.fieldSelector,
    displayName: DrizzleOrm.Schema.fieldSelector,
    imageUrl: DrizzleOrm.Schema.fieldSelector,
    updatesCount: DrizzleOrm.Schema.fieldSelector,
  }

  type gravatarTableRowOptionalFields = {
    exampleId?: string, // todo
    id?: string,
    owner?: string,
    displayName?: string,
    imageUrl?: string,
    updatesCount?: int,
  }

  let gravatar: table<gravatarTableRow> = pgTable(~name="gravatar", ~fields=gravatarTablefields)
}
