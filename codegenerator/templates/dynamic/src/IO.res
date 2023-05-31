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

  module RawEvents = {
    let rawEventsDict: ref<Js.Dict.t<Types.inMemoryStoreRow<Types.rawEventsEntity>>> = ref(
      Js.Dict.empty(),
    )

    let getRawEvents = (~id: string) => {
      let row = Js.Dict.get(rawEventsDict.contents, id)
      row->Belt.Option.map(row => row.entity)
    }

    let setRawEvents = (~entity: Types.rawEventsEntity, ~crud: Types.crud) => {
      let key = EventUtils.getEventIdKeyString(
        ~chainId=entity.chainId,
        ~eventId=entity.eventId,
      )
      let rawEventCurrentCrud =
        rawEventsDict.contents
        ->Js.Dict.get(key)
        ->Belt.Option.map(row => {
          row.crud
        })

      rawEventsDict.contents->Js.Dict.set(
        key,
        {eventData: {chainId: entity.chainId, eventId: entity.eventId}, entity, crud: entityCurrentCrud(rawEventCurrentCrud, crud)},
      )
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

  let set{{entity.name.capitalized}} = (~entity: Types.{{entity.name.uncapitalized}}Entity, ~crud: Types.crud, ~eventData: Types.eventData) => {
    let {{entity.name.uncapitalized}}CurrentCrud = Js.Dict.get(
      {{entity.name.uncapitalized}}Dict.contents,
      entity.id,
    )->Belt.Option.map(row => {
      row.crud
    })



    {{entity.name.uncapitalized}}Dict.contents->Js.Dict.set(entity.id, {eventData, entity, crud: entityCurrentCrud({{entity.name.uncapitalized}}CurrentCrud, crud)})
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

let loadEntities = async (sql, entityBatch: array<Types.entityRead>) => {
  {{#each entities as | entity |}}
  let unique{{entity.name.capitalized}}Dict = Js.Dict.empty()

  {{/each}}
  entityBatch->Belt.Array.forEach(readEntity => {
    switch readEntity {
    {{#each entities as | entity |}}
    | {{entity.name.capitalized}}Read(entity{{#if entity.relational_params.[0]}}, {{entity.name.uncapitalized}}Load{{/if}}) =>
      let _ = Js.Dict.set(unique{{entity.name.capitalized}}Dict, readEntity->Types.entitySerialize, entity)
    {{/each}}
    }
  })

  {{#each entities as | entity |}}
  let {{entity.name.uncapitalized}}EntitiesArray = await sql->DbFunctions.{{entity.name.capitalized}}.read{{entity.name.capitalized}}Entities(
    Js.Dict.values(unique{{entity.name.capitalized}}Dict),
  )

  {{entity.name.uncapitalized}}EntitiesArray->Belt.Array.forEach((readRow) =>
    {
      let {entity, eventData} = DbFunctions.{{entity.name.capitalized}}.readRowToReadEntityData(readRow)
      InMemoryStore.{{entity.name.capitalized}}.set{{entity.name.capitalized}}(~entity, ~eventData, ~crud=Types.Read)
    }
  )

  {{/each}}
}

let executeBatch = async (sql) => {
  let rawEventsRows = InMemoryStore.RawEvents.rawEventsDict.contents->Js.Dict.values

  let deleteRawEventsIdsPromise = (sql) => {
    let deleteRawEventsIds =
      rawEventsRows
      ->Belt.Array.keepMap(rawEventsRow =>
        rawEventsRow.crud == Types.Delete ? Some(rawEventsRow.entity) : None
      )
      ->Belt.Array.map(rawEvents =>
      (rawEvents.chainId, rawEvents.eventId)
      )

    if deleteRawEventsIds->Belt.Array.length > 0 {
      sql->DbFunctions.RawEvents.batchDeleteRawEvents(deleteRawEventsIds)
    } else {
      ()->Promise.resolve
    }
  }

  let setRawEventsPromise = (sql) => {
    let setRawEvents =
      rawEventsRows->Belt.Array.keepMap(rawEventsRow =>
        rawEventsRow.crud == Types.Create || rawEventsRow.crud == Update
          ? Some(rawEventsRow.entity)
          : None
      )

    if setRawEvents->Belt.Array.length > 0 {
      sql->DbFunctions.RawEvents.batchSetRawEvents(setRawEvents)
    } else {
      ()->Promise.resolve
    }
  }

  {{#each entities as | entity |}}
  let {{entity.name.uncapitalized}}Rows = InMemoryStore.{{entity.name.capitalized}}.{{entity.name.uncapitalized}}Dict.contents->Js.Dict.values

  let delete{{entity.name.capitalized}}IdsPromise = (sql) => {
    let delete{{entity.name.capitalized}}Ids =
      {{entity.name.uncapitalized}}Rows
      ->Belt.Array.keepMap({{entity.name.uncapitalized}}Row =>
        {{entity.name.uncapitalized}}Row.crud == Types.Delete ? Some({{entity.name.uncapitalized}}Row.entity) : None
      )
      ->Belt.Array.map({{entity.name.uncapitalized}} => {{entity.name.uncapitalized}}.id)

      if delete{{entity.name.capitalized}}Ids->Belt.Array.length > 0 {
        sql->DbFunctions.{{entity.name.capitalized}}.batchDelete{{entity.name.capitalized}}(delete{{entity.name.capitalized}}Ids)
      } else {
        ()->Promise.resolve
      }
  }
  let set{{entity.name.capitalized}}Promise = (sql) => {
    let set{{entity.name.capitalized}} =
      {{entity.name.uncapitalized}}Rows->Belt.Array.keepMap({{entity.name.uncapitalized}}Row =>
        {{entity.name.uncapitalized}}Row.crud == Types.Create || {{entity.name.uncapitalized}}Row.crud == Update
          ? Some({
            ...{{entity.name.uncapitalized}}Row,
            entity: {{entity.name.uncapitalized}}Row.entity->Types.serialize{{entity.name.capitalized}}Entity,
          }) 
          : None
      )

      if set{{entity.name.capitalized}}->Belt.Array.length > 0 {
         sql->DbFunctions.{{entity.name.capitalized}}.batchSet{{entity.name.capitalized}}(set{{entity.name.capitalized}})
      } else {
        ()->Promise.resolve
      }
  }

  {{/each}}

  let res = await sql->Postgres.beginSql((sql)=>{
     [
      sql->deleteRawEventsIdsPromise,
      sql->setRawEventsPromise,
      {{#each entities as | entity |}}
      sql->delete{{entity.name.capitalized}}IdsPromise,
      sql->set{{entity.name.capitalized}}Promise,
      {{/each}}
    ]
  })

  res
}
