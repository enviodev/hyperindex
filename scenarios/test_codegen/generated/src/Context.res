open Types

let loadedEntities = {
  getGravatarById: id => IO.InMemoryStore.Gravatar.getGravatar(~id),
  //Note this should call the read function in handlers and grab all the loaded entities related to this event,
  getAllLoadedGravatar: () => [], //TODO: likely will delete
}

%%private(
  let context = {
    gravatar: {
      insert: gravatarInsert => {
        IO.InMemoryStore.Gravatar.setGravatar(~gravatar=gravatarInsert, ~crud=Types.Create)
      },
      update: gravatarUpdate => {
        IO.InMemoryStore.Gravatar.setGravatar(~gravatar=gravatarUpdate, ~crud=Types.Update)
      },
      loadedEntities,
    },
  }
)

let getContext = () => context
