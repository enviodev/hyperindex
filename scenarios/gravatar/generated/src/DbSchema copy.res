open DrizzleOrm.Schema

type gravatarTablefields = {
  id: field,
  owner: field,
  displayName: field,
  imageUrl: field,
  updatesCount: field,
}

%%private(
  let gravatarTablefields = {
    id: text("id")->primaryKey,
    owner: text("owner of the gravatar"),
    displayName: text("display name of the gravatar"),
    imageUrl: text("image url of the gravatar"),
    updatesCount: integer("updates count of the gravatar"),
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
