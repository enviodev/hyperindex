open DrizzleOrm

{{#each entities as |entity|}}
module {{entity.name.capitalized}} = {
  /// Below should be generated from the schema:
  type {{entity.name.uncapitalized}}Values

  let {{entity.name.uncapitalized}}Values: Drizzle.values<Types.{{entity.name.uncapitalized}}Entity, {{entity.name.uncapitalized}}Values> = (
    insertion,
    {{entity.name.uncapitalized}}Entities,
  ) => insertion->Drizzle.values({{entity.name.uncapitalized}}Entities)

  let batchSet{{entity.name.capitalized}} = async (batch: array<Types.{{entity.name.uncapitalized}}Entity>) => {
    let get{{entity.name.capitalized}}WithoutId = (
      {{entity.name.uncapitalized}}Entity: Types.{{entity.name.uncapitalized}}Entity,
    ): DbSchema.{{entity.name.capitalized}}.{{entity.name.uncapitalized}}TableRowOptionalFields => {
      {
        owner: {{entity.name.uncapitalized}}Entity.owner,
        displayName: {{entity.name.uncapitalized}}Entity.displayName,
        imageUrl: {{entity.name.uncapitalized}}Entity.imageUrl,
        updatesCount: {{entity.name.uncapitalized}}Entity.updatesCount,
      }
    }

    let db = await DbProvision.getDb()
    await batch
    ->Belt.Array.map(dbEntry => {
      db
      ->Drizzle.insert(~table=DbSchema.{{entity.name.capitalized}}.{{entity.name.uncapitalized}})
      ->{{entity.name.uncapitalized}}Values(dbEntry)
      ->Drizzle.onConflictDoUpdate({
        target: DbSchema.{{entity.name.capitalized}}.{{entity.name.uncapitalized}}.id,
        set: get{{entity.name.capitalized}}WithoutId(dbEntry),
      })
    })
    ->Promise.all
  }

  let batchDelete{{entity.name.capitalized}} = async (batch: array<Types.id>) => {
    let db = await DbProvision.getDb()
    await batch
    ->Belt.Array.map(entityIdToDelete => {
      db
      ->Drizzle.delete(~table=DbSchema.{{entity.name.capitalized}}.{{entity.name.uncapitalized}})
      ->Drizzle.where(~condition=Drizzle.eq(~field=DbSchema.{{entity.name.capitalized}}.{{entity.name.uncapitalized}}.id, ~value=entityIdToDelete))
    })
    ->Promise.all
  }

  let read{{entity.name.capitalized}}Entities = async ({{entity.name.uncapitalized}}Ids: array<Types.id>): array<Types.{{entity.name.uncapitalized}}Entity> => {
    let db = await DbProvision.getDb()
    let result =
      await {{entity.name.uncapitalized}}Ids
      ->Belt.Array.map({{entity.name.uncapitalized}}Id => {
        db
        ->Drizzle.select
        ->Drizzle.from(~table=DbSchema.{{entity.name.capitalized}}.{{entity.name.uncapitalized}})
        ->Drizzle.where(~condition=Drizzle.eq(~field=DbSchema.{{entity.name.capitalized}}.{{entity.name.uncapitalized}}.id, ~value={{entity.name.uncapitalized}}Id))
      })
      ->Promise.all

    result->Belt.Array.concatMany
  }
}
{{/each}}
