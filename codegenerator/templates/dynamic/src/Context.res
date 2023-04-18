{{#each contracts as | contract |}}
module {{contract.name.capitalized}}Contract = {
{{#each contract.events as | event |}}
  module {{event.name.capitalized}}Event = {
    type context = Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.context

    %%private(
      let context: context = {
          {{#each ../../entities as | entity |}}
          {{entity.name.uncapitalized}}: {
              insert: entity => {IO.InMemoryStore.{{entity.name.capitalized}}.set{{entity.name.capitalized}}(~{{entity.name.uncapitalized}} = entity, ~crud = Types.Create)},
              update: entity => {IO.InMemoryStore.{{entity.name.capitalized}}.set{{entity.name.capitalized}}(~{{entity.name.uncapitalized}} = entity, ~crud = Types.Update)},
              delete: id => (),
              //TODO hardcoded - retrieve from config.yaml
              gravatarWithChanges: () => Obj.magic(), 
            },
        {{/each}}
      }
    )
    let getContext: unit => context = () => context
    let getLoaderContext: unit => Types.GravatarContract.UpdatedGravatarEvent.loaderContext = ()->Obj.magic
  }
{{/each}}
}
{{/each}}
