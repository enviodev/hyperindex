{{#each chain_configs as | chain_config |}}
{{#each chain_config.contracts as | contract |}}
// let {{contract.name.uncapitalized}}Abi = `
// {{contract.abi}}
// `->Js.Json.parseExn
let {{contract.name.uncapitalized}}Abi = `{"TODO": "Fix Me"}`->Js.Json.parseExn

{{/each}}
{{/each}}

