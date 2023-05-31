{{#each contracts as | contract |}}
module {{contract.name.capitalized}}Contract = {
{{#each contract.events as | event |}}
  module {{event.name.capitalized}}Event = {
    type context = Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.context

    type contextCreatorFunctions = {
      getLoaderContext: unit => Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.loaderContext,
      getContext: (~eventData: Types.eventData) => Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.context,
      getEntitiesToLoad: unit => array<Types.entityRead>
    }
    let contextCreator: unit => contextCreatorFunctions = () => {
      {{#each event.required_entities as | required_entity |}}
      {{#each required_entity.labels as |label| }}
      let optIdOf_{{label}} = ref(None)
      {{/each}}
      {{/each}}

      let entitiesToLoad: array<Types.entityRead> = []

      @warning("-16")
      let loaderContext: Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.loaderContext = {
      {{#each event.required_entities as | required_entity |}}
        {{required_entity.name.uncapitalized}}: {
      {{#each required_entity.labels as |label| }}
          {{label}}Load: (id: Types.id{{#if required_entity.entity_fields_of_required_entity.[0]}}, ~loaders={}{{/if}}) => {
            optIdOf_{{label}} := Some(id)

            let _ = Js.Array2.push(entitiesToLoad, Types.{{required_entity.name.capitalized}}Read(id{{#if required_entity.entity_fields_of_required_entity.[0]}}, loaders{{/if}}))
          },
      {{/each}}
        },
      {{/each}}
      }
      {
        getEntitiesToLoad: () => entitiesToLoad,
        getLoaderContext: () => loaderContext,
        getContext: (~eventData) => ({
          {{#each ../../entities as | entity |}}
            {{entity.name.uncapitalized}}: {
              insert: entity => {IO.InMemoryStore.{{entity.name.capitalized}}.set{{entity.name.capitalized}}(~entity = entity, ~crud = Types.Create, ~eventData)},
              update: entity => {IO.InMemoryStore.{{entity.name.capitalized}}.set{{entity.name.capitalized}}(~entity = entity, ~crud = Types.Update, ~eventData)},
              delete: id => Logging.warn(`[unimplemented delete] can't delete entity({{entity.name.uncapitalized}}) with ID ${id}.`),
              {{#each event.required_entities as | required_entity |}}
                {{#if (eq entity.name.capitalized required_entity.name.capitalized)}}
                  {{#each required_entity.labels as |label| }}
                  {{label}}: () => optIdOf_{{label}}.contents->Belt.Option.flatMap(id => IO.InMemoryStore.{{required_entity.name.capitalized}}.get{{required_entity.name.capitalized}}(~id)),
                  {{/each}}
                  {{#each required_entity.entity_fields_of_required_entity as | entity_field_of_required_entity |}}
              get{{entity_field_of_required_entity.field_name.capitalized}}: {{entity.name.uncapitalized}} => {
                {{#if entity_field_of_required_entity.is_optional}}
                  let opt{{entity_field_of_required_entity.field_name.capitalized}} = {{entity.name.uncapitalized}}.{{entity_field_of_required_entity.field_name.uncapitalized}}->Belt.Option.map(entityFieldId => IO.InMemoryStore.{{entity_field_of_required_entity.type_name.capitalized}}.get{{entity_field_of_required_entity.type_name.capitalized}}(~id=entityFieldId))
                {{else}}
                  let opt{{entity_field_of_required_entity.field_name.capitalized}} = IO.InMemoryStore.{{entity_field_of_required_entity.type_name.capitalized}}.get{{entity_field_of_required_entity.type_name.capitalized}}(~id={{entity.name.uncapitalized}}.{{entity_field_of_required_entity.field_name.uncapitalized}})
                {{/if}}
              switch opt{{entity_field_of_required_entity.field_name.capitalized}} {
              | Some({{entity_field_of_required_entity.field_name.uncapitalized}}) => {{entity_field_of_required_entity.field_name.uncapitalized}}
              | None =>
                Logging.warn(`{{entity.name.capitalized}} {{entity_field_of_required_entity.field_name.uncapitalized}} data not found. Loading associated {{entity_field_of_required_entity.type_name.uncapitalized}} from database.
Please consider loading the {{entity_field_of_required_entity.type_name.uncapitalized}} in the Update{{entity.name.capitalized}} entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a {{entity_field_of_required_entity.type_name.uncapitalized}} with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },

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
