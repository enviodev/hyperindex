open Types

let loadedEntities = {
  getUserById: id => IO.InMemoryStore.User.getUser(~id),
  //Note this should call the read function in handlers and grab all the loaded entities related to this event,
  getAllLoadedUser: () => [], //TODO: likely will delete
  getGravatarById: id => IO.InMemoryStore.Gravatar.getGravatar(~id),
  //Note this should call the read function in handlers and grab all the loaded entities related to this event,
  getAllLoadedGravatar: () => [], //TODO: likely will delete
}

%%private(
  let context = {
    user: {
      insert: userInsert => {
        IO.InMemoryStore.User.setUser(~user=userInsert, ~crud=Types.Create)
      },
      update: userUpdate => {
        IO.InMemoryStore.User.setUser(~user=userUpdate, ~crud=Types.Update)
      },
      loadedEntities,
    },
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
