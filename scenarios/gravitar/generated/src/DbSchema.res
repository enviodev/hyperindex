open DrizzleOrm.Schema

type gravatarTableColumns = {
  id: column,
  owner: column,
  displayName: column,
  imageUrl: column,
  updatesCount: column,
}
let gravatar = pgTable(
  ~name="gravatar",
  ~columns={
    id: serial("id")->primaryKey,
    owner: text("owner osf the gravatar"),
    displayName: text("display name of the gravatar"),
    imageUrl: text("image url of the gravatar"),
    updatesCount: integer("updates count of the gravatar"),
  },
)
