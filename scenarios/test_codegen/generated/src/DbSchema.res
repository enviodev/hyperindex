open DrizzleOrm.Schema

type id = string

module User = {
  type userTableFields = {
    id: field,
    address: field,
    gravatar: field,
  }

  %%private(
    let userTableFields = {
      id: text("id")->primaryKey, // todo param.drizzleType eg. text integer etc // todo snake case
      address: text("address"), // todo param.drizzleType eg. text integer etc // todo snake case
      gravatar: text("gravatar"), // todo param.drizzleType eg. text integer etc // todo snake case
    }
  )

  type userTableRow = {
    id: DrizzleOrm.Schema.fieldSelector,
    address: DrizzleOrm.Schema.fieldSelector,
    gravatar: DrizzleOrm.Schema.fieldSelector,
  }

  type userTableRowOptionalFields = {
    id?: string,
    address?: string,
    gravatar?: option<id>,
  }

  let user: table<userTableRow> = pgTable(~name="user", ~fields=userTableFields)
}

// re-declaired here to create exports for db migrations
let user = User.user

module Gravatar = {
  type gravatarTableFields = {
    id: field,
    owner: field,
    displayName: field,
    imageUrl: field,
    updatesCount: field,
  }

  %%private(
    let gravatarTableFields = {
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
    owner?: id,
    displayName?: string,
    imageUrl?: string,
    updatesCount?: int,
  }

  let gravatar: table<gravatarTableRow> = pgTable(~name="gravatar", ~fields=gravatarTableFields)
}

// re-declaired here to create exports for db migrations
let gravatar = Gravatar.gravatar
