open DrizzleOrm

module User = {
  /// Below should be generated from the schema:
  type userValues

  let userValues: Drizzle.values<Types.userEntity, userValues> = (insertion, userEntities) =>
    insertion->Drizzle.values(userEntities)

  let batchSetUser = async (batch: array<Types.userEntity>) => {
    let getUserWithoutId = (
      userEntity: Types.userEntity,
    ): DbSchema.User.userTableRowOptionalFields => {
      {
        id: userEntity.id,
        address: userEntity.address,
        gravatar: userEntity.gravatar,
      }
    }

    let db = await DbProvision.getDb()
    await batch
    ->Belt.Array.map(dbEntry => {
      db
      ->Drizzle.insert(~table=DbSchema.User.user)
      ->userValues(dbEntry)
      ->Drizzle.onConflictDoUpdate({
        target: DbSchema.User.user.id,
        set: getUserWithoutId(dbEntry),
      })
    })
    ->Promise.all
  }

  let batchDeleteUser = async (batch: array<Types.id>) => {
    let db = await DbProvision.getDb()
    await batch
    ->Belt.Array.map(entityIdToDelete => {
      db
      ->Drizzle.delete(~table=DbSchema.User.user)
      ->Drizzle.where(~condition=Drizzle.eq(~field=DbSchema.User.user.id, ~value=entityIdToDelete))
    })
    ->Promise.all
  }

  let readUserEntities = async (userIds: array<Types.id>): array<Types.userEntity> => {
    let db = await DbProvision.getDb()
    let result =
      await userIds
      ->Belt.Array.map(userId => {
        db
        ->Drizzle.select
        ->Drizzle.from(~table=DbSchema.User.user)
        ->Drizzle.where(~condition=Drizzle.eq(~field=DbSchema.User.user.id, ~value=userId))
      })
      ->Promise.all

    result->Belt.Array.concatMany
  }
}
module Gravatar = {
  /// Below should be generated from the schema:
  type gravatarValues

  let gravatarValues: Drizzle.values<Types.gravatarEntity, gravatarValues> = (
    insertion,
    gravatarEntities,
  ) => insertion->Drizzle.values(gravatarEntities)

  let batchSetGravatar = async (batch: array<Types.gravatarEntity>) => {
    let getGravatarWithoutId = (
      gravatarEntity: Types.gravatarEntity,
    ): DbSchema.Gravatar.gravatarTableRowOptionalFields => {
      {
        id: gravatarEntity.id,
        owner: gravatarEntity.owner,
        displayName: gravatarEntity.displayName,
        imageUrl: gravatarEntity.imageUrl,
        updatesCount: gravatarEntity.updatesCount,
      }
    }

    let db = await DbProvision.getDb()
    await batch
    ->Belt.Array.map(dbEntry => {
      db
      ->Drizzle.insert(~table=DbSchema.Gravatar.gravatar)
      ->gravatarValues(dbEntry)
      ->Drizzle.onConflictDoUpdate({
        target: DbSchema.Gravatar.gravatar.id,
        set: getGravatarWithoutId(dbEntry),
      })
    })
    ->Promise.all
  }

  let batchDeleteGravatar = async (batch: array<Types.id>) => {
    let db = await DbProvision.getDb()
    await batch
    ->Belt.Array.map(entityIdToDelete => {
      db
      ->Drizzle.delete(~table=DbSchema.Gravatar.gravatar)
      ->Drizzle.where(
        ~condition=Drizzle.eq(~field=DbSchema.Gravatar.gravatar.id, ~value=entityIdToDelete),
      )
    })
    ->Promise.all
  }

  let readGravatarEntities = async (gravatarIds: array<Types.id>): array<Types.gravatarEntity> => {
    let db = await DbProvision.getDb()
    let result =
      await gravatarIds
      ->Belt.Array.map(gravatarId => {
        db
        ->Drizzle.select
        ->Drizzle.from(~table=DbSchema.Gravatar.gravatar)
        ->Drizzle.where(
          ~condition=Drizzle.eq(~field=DbSchema.Gravatar.gravatar.id, ~value=gravatarId),
        )
      })
      ->Promise.all

    result->Belt.Array.concatMany
  }
}
