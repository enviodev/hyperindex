open DrizzleOrm.Schema

{{#each entities as |entity|}}
module {{entity.name.capitalized}} = {
  type {{entity.name.uncapitalized}}Tablefields = {
    {{#each entity.params as |param|}}
    {{param.key}}: field,
    {{/each}}
  }

  %%private(
    let {{entity.name.uncapitalized}}Tablefields = {
      {{#each entity.params as |param|}}
      {{param.key}}: text("{{param.key}}"){{#if (eq param.key "id")}}->primaryKey{{/if}}, // todo param.drizzleType eg. text integer etc // todo snake case
      {{/each}}
    }
  )

  type {{entity.name.uncapitalized}}TableRow = {
    {{#each entity.params as |param|}}
    {{param.key}}: DrizzleOrm.Schema.fieldSelector,    
    {{/each}}
  }

  type {{entity.name.uncapitalized}}TableRowOptionalFields = {
    {{#each entity.params as |param|}}
    {{param.key}}?: {{param.type_}},
    {{/each}}    
  }

  let {{entity.name.uncapitalized}}: table<{{entity.name.uncapitalized}}TableRow> = pgTable(~name="{{entity.name.uncapitalized}}", ~fields={{entity.name.uncapitalized}}Tablefields)
}

// re-declaired here to create exports for db migrations
let {{entity.name.uncapitalized}} = {{entity.name.capitalized}}.{{entity.name.uncapitalized}}

{{/each}}
