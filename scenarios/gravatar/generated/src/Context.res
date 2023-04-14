open Types

let loadedEntities = {
  getById: id => IO.InMemoryStore.getGravatar(~id),
  getAllLoaded: () => [], //Note this should call the read function in handlers and grab all the loaded entities related to this event,
}

%%private(
  let context = {
    gravatar: {
      insert: gravatarInsert => {
        IO.InMemoryStore.setGravatar(~gravatar=gravatarInsert, ~crud=Types.Create)
      },
      update: gravatarUpdate => {
        IO.InMemoryStore.setGravatar(~gravatar=gravatarUpdate, ~crud=Types.Update)
      },
      loadedEntities,
    },
  }
)

let getContext = () => context
