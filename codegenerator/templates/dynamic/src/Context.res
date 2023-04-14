open Types

let loadedEntities = {
{{#each entities as |entity|}}
  get{{entity.name.capitalized}}ById: id => IO.InMemoryStore.{{entity.name.capitalized}}.get{{entity.name.capitalized}}(~id),
  //Note this should call the read function in handlers and grab all the loaded entities related to this event,
  getAllLoaded{{entity.name.capitalized}}: () => [], //TODO: likely will delete
{{/each}}
}

%%private(
  let context = {
{{#each entities as |entity|}}
    {{entity.name.uncapitalized}}: {
      insert: {{entity.name.uncapitalized}}Insert => {
        IO.InMemoryStore.{{entity.name.capitalized}}.set{{entity.name.capitalized}}(~{{entity.name.uncapitalized}}={{entity.name.uncapitalized}}Insert, ~crud=Types.Create)
      },
      update: {{entity.name.uncapitalized}}Update => {
        IO.InMemoryStore.{{entity.name.capitalized}}.set{{entity.name.capitalized}}(~{{entity.name.uncapitalized}}={{entity.name.uncapitalized}}Update, ~crud=Types.Update)
      },
      loadedEntities,
    },
{{/each}}
  }
)

let getContext = () => context
