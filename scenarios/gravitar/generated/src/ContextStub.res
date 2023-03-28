type gravitarController = {
  insert: Types.gravatarEntity => unit,
  update: Types.gravatarEntity => unit,
}
type context = {@as("Gravatar") gravatar: gravitarController}

let context = {
  gravatar: {
    insert: gravatarInsert => Js.log2("Insert:", gravatarInsert.id),
    update: grvatarUpdate => Js.log2("update:", grvatarUpdate.id),
  },
}
