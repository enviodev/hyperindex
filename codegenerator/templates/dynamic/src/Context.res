{{#each contracts as | contract |}}
module {{contract.name.capitalized}}Contract = {
{{#each contract.events as | event |}}
  module {{event.name.capitalized}}Event = {
    type context = Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.context

    type contextCreatorFunctions = {
      getLoaderContext: unit => Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.loaderContext,
      getContext: unit => Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.context,
    }
    let contextCreator: unit => contextCreatorFunctions = () => {
      // TODO: loop through each of the named arguments.
      let optIdOf_gravatarWithChanges = ref(None)

      let loaderContext: Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.loaderContext = {
        // TODO: loop through each of the named arguments.
        gravatar: {
          gravatarWithChangesLoad: (id: Types.id) => {
            optIdOf_gravatarWithChanges := Some(id)
          }
        }
      }
      {
        getLoaderContext: () => loaderContext,
        getContext: () => ({

        {{#each ../../entities as | entity |}}
          {{entity.name.uncapitalized}}: {
              insert: entity => {IO.InMemoryStore.{{entity.name.capitalized}}.set{{entity.name.capitalized}}(~{{entity.name.uncapitalized}} = entity, ~crud = Types.Create)},
              update: entity => {IO.InMemoryStore.{{entity.name.capitalized}}.set{{entity.name.capitalized}}(~{{entity.name.uncapitalized}} = entity, ~crud = Types.Update)},
              delete: id => (),
              //TODO hardcoded - retrieve from config.yaml
              gravatarWithChanges: () => optIdOf_gravatarWithChanges.contents->Belt.Option.flatMap(id => IO.InMemoryStore.Gravatar.getGravatar(~id)),
            },
        {{/each}}
        })
      }
    }

  }
{{/each}}
}
{{/each}}
