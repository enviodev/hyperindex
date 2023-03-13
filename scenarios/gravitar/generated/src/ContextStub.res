type gravitarController = {
  insert: SchemaTypes.gravitar => unit,
  update: SchemaTypes.gravitar => unit,
}

type context = {@as("Gravitar") gravitar: gravitarController}

let context = {
  gravatar: {
    insert: Js.log("inserted"),
    update: Js.log("updated"),
  },
}
