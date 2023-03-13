type gravitarController = {
  insert: SchemaTypes.gravatar => unit,
  update: SchemaTypes.gravatar => unit,
}
type context = {@as("Gravatar") gravatar: gravitarController}

let context = {
  gravatar: {
    insert: gravatarInsert => Js.log2("Insert:", gravatarInsert.id),
    update: grvatarUpdate => Js.log2("update:", grvatarUpdate.id),
  },
}
