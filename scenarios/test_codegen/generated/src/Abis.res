let gravatarAbi = `
[{"type":"event","name":"NewGravatar","inputs":[{"name":"id","type":"uint256","indexed":false},{"name":"owner","type":"address","indexed":false},{"name":"displayName","type":"string","indexed":false},{"name":"imageUrl","type":"string","indexed":false}],"anonymous":false},{"type":"event","name":"TestEvent","inputs":[{"name":"id","type":"uint256","indexed":false},{"name":"user","type":"address","indexed":false},{"name":"contactDetails","type":"tuple","indexed":false,"components":[{"type":"string"},{"type":"string"}]}],"anonymous":false},{"type":"event","name":"UpdatedGravatar","inputs":[{"name":"id","type":"uint256","indexed":false},{"name":"owner","type":"address","indexed":false},{"name":"displayName","type":"string","indexed":false},{"name":"imageUrl","type":"string","indexed":false}],"anonymous":false}]
`->Js.Json.parseExn

let nftFactoryAbi = `
[{"type":"event","name":"SimpleNftCreated","inputs":[{"name":"name","type":"string","indexed":false},{"name":"symbol","type":"string","indexed":false},{"name":"maxSupply","type":"uint256","indexed":false},{"name":"contractAddress","type":"address","indexed":false}],"anonymous":false}]
`->Js.Json.parseExn

let simpleNftAbi = `
[{"type":"event","name":"Transfer","inputs":[{"name":"from","type":"address","indexed":true},{"name":"to","type":"address","indexed":true},{"name":"tokenId","type":"uint256","indexed":true}],"anonymous":false}]
`->Js.Json.parseExn
