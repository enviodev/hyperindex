{{#each contracts as | contract |}}
module {{contract.name.capitalized}}Contract = {
{{#each contract.events as | event |}}
  module {{event.name.capitalized}}Event = {
    type context = Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.context

    type contextCreatorFunctions = {
      getLoaderContext: unit => Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.loaderContext,
      getContext: unit => Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.context,
      getEntitiesToLoad: unit => array<Types.entityRead>
    }
    let contextCreator: unit => contextCreatorFunctions = () => {
      {{#each event.required_entities as | required_entity |}}
      {{#each required_entity.labels as |label| }}
      let optIdOf_{{label}} = ref(None)
      {{/each}}
      {{/each}}

      let entitiesToLoad: array<Types.entityRead> = []

      let loaderContext: Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.loaderContext = {
      {{#each event.required_entities as | required_entity |}}
        {{required_entity.name.uncapitalized}}: {
      {{#each required_entity.labels as |label| }}
          {{label}}Load: (id: Types.id) => {
            optIdOf_{{label}} := Some(id)

            let _ = Js.Array2.push(entitiesToLoad, Types.{{required_entity.name.capitalized}}Read(id))
          }
      {{/each}}
        },
      {{/each}}
      }
      {
        getEntitiesToLoad: () => entitiesToLoad,
        getLoaderContext: () => loaderContext,
        getContext: () => ({
          {{#each ../../entities as | entity |}}
            {{entity.name.uncapitalized}}: {
              insert: entity => {IO.InMemoryStore.{{entity.name.capitalized}}.set{{entity.name.capitalized}}(~{{entity.name.uncapitalized}} = entity, ~crud = Types.Create)},
              update: entity => {IO.InMemoryStore.{{entity.name.capitalized}}.set{{entity.name.capitalized}}(~{{entity.name.uncapitalized}} = entity, ~crud = Types.Update)},
              delete: id => Js.Console.warn(`[unimplemented delete] can't delete entity({{entity.name.uncapitalized}}) with ID ${id}.`),
              {{#each event.required_entities as | required_entity |}}
                {{#if (eq entity.name.capitalized required_entity.name.capitalized)}}
                  {{#each required_entity.labels as |label| }}
                  {{label}}: () => optIdOf_{{label}}.contents->Belt.Option.flatMap(id => IO.InMemoryStore.{{required_entity.name.capitalized}}.get{{required_entity.name.capitalized}}(~id)),
                  {{/each}}
                {{/if}}
              {{/each}}
            },
          {{/each}}
        })
      }
    }
  }
{{/each}}
}
{{/each}}
