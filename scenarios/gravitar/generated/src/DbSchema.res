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
    owner: text("owner osf the gravatar"),
    displayName: text("display name of the gravatar"),
    imageUrl: text("image url of the gravatar"),
    updatesCount: integer("updates count of the gravatar"),
  }
)

type gravitarTableRow = {
  id: string,
  owner: string,
  displayName: string,
  imageUrl: string,
  updatesCount: int,
}

type gravitarTableRowOptionalFields = {
  id?: string,
  owner?: string,
  displayName?: string,
  imageUrl?: string,
  updatesCount?: int,
}

let gravatar: table<gravitarTableRow> = pgTable(~name="gravatar", ~fields=gravatarTablefields)
