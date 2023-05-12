module InMemoryStore = {

  let entityCurrentCrud = (currentCrud: option<Types.crud>, nextCrud: Types.crud) => {

     switch (currentCrud, nextCrud) {
    | (Some(Create), Create) => Types.Create
    | (Some(Read), Create)
    | (Some(Update), Create)
    | (Some(Delete), Create) =>
      // dont know if this is an update or create
      Update
    | (Some(Create), Read) => Create
    | (Some(Read), Read) => Read
    | (Some(Update), Read) => Update
    | (Some(Delete), Read) => Delete
    | (Some(Create), Update) => Create
    | (Some(Read), Update) => Update
    | (Some(Update), Update) => Update
    | (Some(Delete), Update) => Update
    | (Some(Create), Delete) => Delete // interesting to note to line 23
    | (Some(Read), Delete) => Delete
    | (Some(Update), Delete) => Delete
    | (Some(Delete), Delete) => Delete
    | (None, _) => nextCrud
    }
  }

{{#each entities as | entity |}}

module {{entity.name.capitalized}} = {
  let {{entity.name.uncapitalized}}Dict: ref<Js.Dict.t<Types.inMemoryStoreRow<Types.{{entity.name.uncapitalized}}Entity>>> = ref(
    Js.Dict.empty(),
  )

  let get{{entity.name.capitalized}} = (~id: string) => {
    let row = Js.Dict.get({{entity.name.uncapitalized}}Dict.contents, id)
    row->Belt.Option.map(row => row.entity)
  }

  let set{{entity.name.capitalized}} = (~{{entity.name.uncapitalized}}: Types.{{entity.name.uncapitalized}}Entity, ~crud: Types.crud) => {
    let {{entity.name.uncapitalized}}CurrentCrud = Js.Dict.get(
      {{entity.name.uncapitalized}}Dict.contents,
      {{entity.name.uncapitalized}}.id,
    )->Belt.Option.map(row => {
      row.crud
    })



    Js.Dict.set({{entity.name.uncapitalized}}Dict.contents, {{entity.name.uncapitalized}}.id, {entity: {{entity.name.uncapitalized}}, crud: entityCurrentCrud({{entity.name.uncapitalized}}CurrentCrud, crud)})
  }
  }
  {{/each}}
  let resetStore = () => {
  {{#each entities as | entity |}}
    {{entity.name.capitalized}}.{{entity.name.uncapitalized}}Dict := Js.Dict.empty()
  {{/each}}
  }
}

type uniqueEntityReadIds = Js.Dict.t<Types.id>
type allEntityReads = Js.Dict.t<uniqueEntityReadIds>

let loadEntities = async (entityBatch: array<Types.entityRead>) => {
  {{#each entities as | entity |}}
  let unique{{entity.name.capitalized}}Dict = Js.Dict.empty()

  {{/each}}
  entityBatch->Belt.Array.forEach(readEntity => {
    switch readEntity {
    {{#each entities as | entity |}}
    | {{entity.name.capitalized}}Read(entity) =>
      let _ = Js.Dict.set(unique{{entity.name.capitalized}}Dict, readEntity->Types.entitySerialize, entity)
    {{/each}}
    }
  })

  {{#each entities as | entity |}}
  let {{entity.name.uncapitalized}}EntitiesArray = await DbFunctions.{{entity.name.capitalized}}.read{{entity.name.capitalized}}Entities(
    Js.Dict.values(unique{{entity.name.capitalized}}Dict),
  )

  {{entity.name.uncapitalized}}EntitiesArray->Belt.Array.forEach({{entity.name.uncapitalized}} =>
    InMemoryStore.{{entity.name.capitalized}}.set{{entity.name.capitalized}}(~{{entity.name.uncapitalized}}, ~crud=Types.Read)
  )

  {{/each}}
}

let createBatch = () => {
  InMemoryStore.resetStore()
}

let executeBatch = async () => {
  {{#each entities as | entity |}}
  let {{entity.name.uncapitalized}}Rows = InMemoryStore.{{entity.name.capitalized}}.{{entity.name.uncapitalized}}Dict.contents->Js.Dict.values

  let delete{{entity.name.capitalized}}IdsPromise = () => {
    let delete{{entity.name.capitalized}}Ids =
      {{entity.name.uncapitalized}}Rows
      ->Belt.Array.keepMap({{entity.name.uncapitalized}}Row =>
        {{entity.name.uncapitalized}}Row.crud == Types.Delete ? Some({{entity.name.uncapitalized}}Row.entity) : None
      )
      ->Belt.Array.map({{entity.name.uncapitalized}} => {{entity.name.uncapitalized}}.id)

      if delete{{entity.name.capitalized}}Ids->Belt.Array.length > 0 {
        DbFunctions.{{entity.name.capitalized}}.batchDelete{{entity.name.capitalized}}(delete{{entity.name.capitalized}}Ids)
      } else {
        ()->Promise.resolve
      }
  }
  let set{{entity.name.capitalized}}Promise = () => {
    let set{{entity.name.capitalized}} =
      {{entity.name.uncapitalized}}Rows->Belt.Array.keepMap({{entity.name.uncapitalized}}Row =>
        {{entity.name.uncapitalized}}Row.crud == Types.Create || {{entity.name.uncapitalized}}Row.crud == Update
          ? Some({{entity.name.uncapitalized}}Row.entity)
          : None
      )

      if set{{entity.name.capitalized}}->Belt.Array.length > 0 {
         DbFunctions.{{entity.name.capitalized}}.batchSet{{entity.name.capitalized}}(set{{entity.name.capitalized}})
      } else {
        ()->Promise.resolve
      }
  }

  {{/each}}
  await [
    {{#each entities as | entity |}}
    delete{{entity.name.capitalized}}IdsPromise(),
    set{{entity.name.capitalized}}Promise(),
    {{/each}}
  ]->Promise.all
}