{{#each chain_configs as | chain_config |}}
{{#each chain_config.contracts as | contract |}}
// let {{contract.name.uncapitalized}}Abi = `
// {{contract.abi}}
// `->Js.Json.parseExn
let {{contract.name.uncapitalized}}Abi = `{"TODO": "Fix Me"}`->Js.Json.parseExn

{{/each}}
{{/each}}


// TODO: delete this once proper abi gen works!
let gravatarAbi = `[{"constant":false,"inputs":[{"name":"_imageUrl","type":"string"}],"name":"updateGravatarImage","outputs":[],"payable":false,"stateMutability":"nonpayable","type":"function"},{"constant":false,"inputs":[],"name":"setMythicalGravatar","outputs":[],"payable":false,"stateMutability":"nonpayable","type":"function"},{"constant":true,"inputs":[{"name":"owner","type":"address"}],"name":"getGravatar","outputs":[{"name":"","type":"string"},{"name":"","type":"string"}],"payable":false,"stateMutability":"view","type":"function"},{"constant":true,"inputs":[{"name":"","type":"uint256"}],"name":"gravatarToOwner","outputs":[{"name":"","type":"address"}],"payable":false,"stateMutability":"view","type":"function"},{"constant":true,"inputs":[{"name":"","type":"address"}],"name":"ownerToGravatar","outputs":[{"name":"","type":"uint256"}],"payable":false,"stateMutability":"view","type":"function"},{"constant":false,"inputs":[{"name":"_displayName","type":"string"}],"name":"updateGravatarName","outputs":[],"payable":false,"stateMutability":"nonpayable","type":"function"},{"constant":false,"inputs":[{"name":"_displayName","type":"string"},{"name":"_imageUrl","type":"string"}],"name":"createGravatar","outputs":[],"payable":false,"stateMutability":"nonpayable","type":"function"},{"constant":true,"inputs":[{"name":"","type":"uint256"}],"name":"gravatars","outputs":[{"name":"owner","type":"address"},{"name":"displayName","type":"string"},{"name":"imageUrl","type":"string"}],"payable":false,"stateMutability":"view","type":"function"},{"anonymous":false,"inputs":[{"indexed":false,"name":"id","type":"uint256"},{"indexed":false,"name":"owner","type":"address"},{"indexed":false,"name":"displayName","type":"string"},{"indexed":false,"name":"imageUrl","type":"string"}],"name":"NewGravatar","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"name":"id","type":"uint256"},{"indexed":false,"name":"owner","type":"address"},{"indexed":false,"name":"displayName","type":"string"},{"indexed":false,"name":"imageUrl","type":"string"}],"name":"UpdatedGravatar","type":"event"}]`->Js.Json.parseExn
