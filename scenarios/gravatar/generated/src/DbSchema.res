open DrizzleOrm.Schema

module Gravatar = {
  type gravatarTablefields = {
    id: field,
    owner: field,
    displayName: field,
    imageUrl: field,
    updatesCount: field,
  }

  %%private(
    let gravatarTablefields = {
      id: text("id")->primaryKey, // todo param.drizzleType eg. text integer etc // todo snake case
      owner: text("owner"), // todo param.drizzleType eg. text integer etc // todo snake case
      displayName: text("displayName"), // todo param.drizzleType eg. text integer etc // todo snake case
      imageUrl: text("imageUrl"), // todo param.drizzleType eg. text integer etc // todo snake case
      updatesCount: text("updatesCount"), // todo param.drizzleType eg. text integer etc // todo snake case
    }
  )

  type gravatarTableRow = {
    id: DrizzleOrm.Schema.fieldSelector,
    owner: DrizzleOrm.Schema.fieldSelector,
    displayName: DrizzleOrm.Schema.fieldSelector,
    imageUrl: DrizzleOrm.Schema.fieldSelector,
    updatesCount: DrizzleOrm.Schema.fieldSelector,
  }

  type gravatarTableRowOptionalFields = {
    id?: string,
    owner?: string,
    displayName?: string,
    imageUrl?: string,
    updatesCount?: int,
  }

  let gravatar: table<gravatarTableRow> = pgTable(~name="gravatar", ~fields=gravatarTablefields)
}
